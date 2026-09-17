#!/usr/bin/env bash
#
# Turn on immutable releases for every repository in fleet/repos.txt.
#
#   ./scripts/enable-immutable-releases.sh            # dry run (default)
#   ./scripts/enable-immutable-releases.sh --apply    # write
#
# Immutable releases make a published release's tag and assets impossible to
# move or delete. That turns [HAR-NAME-003] ("never move a published release
# tag") from a written rule into something the platform enforces, and it comes
# with signed attestations.
#
# The setting IS exposed by the REST API — there is no need to click through the
# UI for 29 repositories:
#
#   GET    /repos/{owner}/{repo}/immutable-releases  -> {"enabled":…, "enforced_by_owner":…}
#   PUT    /repos/{owner}/{repo}/immutable-releases  -> 204
#   DELETE /repos/{owner}/{repo}/immutable-releases  -> 204
#
# (Verified against the published GitHub OpenAPI description and a live GET on
# 2026-09-17. It is not a field on the repository object, which is why it does
# not show up in `gh api repos/{owner}/{repo}`.) The authenticated user needs
# admin access on the repository.
#
# Turning this on is one-way in spirit: existing releases stay mutable, but new
# ones cannot be retracted by moving a tag. Disable with the DELETE endpoint if
# it ever has to be undone.
#
# Not every repository can take it. A workflow that attaches or replaces an
# asset on an already-published release breaks the moment the setting is on, so
# those repositories are listed in fleet/immutable-releases-exclude.txt with
# their reason and reported as SKIP. The list is required: losing it would turn
# the setting on for exactly the repositories it breaks, so a missing file is
# fatal rather than an empty exclusion.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
REPOS_FILE="${REPO_ROOT}/fleet/repos.txt"
EXCLUDE_FILE="${REPO_ROOT}/fleet/immutable-releases-exclude.txt"
APPLY=0

usage() {
  cat <<'USAGE'
Usage: enable-immutable-releases.sh [--apply] [--repos FILE] [--exclude FILE]

  --apply         Enable immutable releases. Without it the script only reports
                  the current state of each repository.
  --repos FILE    Repository list to use instead of fleet/repos.txt.
  --exclude FILE  Exclusion list to use instead of
                  fleet/immutable-releases-exclude.txt. Pass /dev/null to
                  exclude nothing.
  -h, --help      This text.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --repos) shift; REPOS_FILE="${1:?--repos needs a path}" ;;
    --exclude) shift; EXCLUDE_FILE="${1:?--exclude needs a path}" ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ! command -v gh >/dev/null 2>&1; then
  printf 'FATAL  gh is not installed\n' >&2
  exit 1
fi

if [ ! -f "$REPOS_FILE" ]; then
  printf 'FATAL  repository list not found: %s\n' "$REPOS_FILE" >&2
  exit 1
fi

if [ ! -e "$EXCLUDE_FILE" ]; then
  printf 'FATAL  exclusion list not found: %s\n' "$EXCLUDE_FILE" >&2
  printf '       Pass --exclude /dev/null to exclude nothing on purpose.\n' >&2
  exit 1
fi

# The reason this repository is excluded, or nothing at all when it is not.
# A line is `owner/name` with the reason after a `#`; a whole-line comment
# carries no repository name and so can never match.
exclude_reason() {
  awk -v want="$1" '
    {
      name = $0
      sub(/#.*/, "", name)
      gsub(/[[:space:]]/, "", name)
      if (name == "" || name != want) next
      reason = ""
      if (index($0, "#") > 0) {
        reason = substr($0, index($0, "#") + 1)
        sub(/^[[:space:]]+/, "", reason)
        sub(/[[:space:]]+$/, "", reason)
      }
      print (reason == "" ? "no reason given" : reason)
      exit
    }
  ' "$EXCLUDE_FILE"
}

if [ "$APPLY" -eq 1 ]; then
  printf 'MODE   apply\n'
else
  printf 'MODE   dry-run (pass --apply to write)\n'
fi
printf 'LIST   %s\n' "$REPOS_FILE"
printf 'SKIPS  %s\n\n' "$EXCLUDE_FILE"

ok=0
failed=0
while IFS= read -r line || [ -n "$line" ]; do
  repo="${line%%#*}"
  repo="$(printf '%s' "$repo" | tr -d '[:space:]')"
  [ -z "$repo" ] && continue

  reason="$(exclude_reason "$repo")"
  if [ -n "$reason" ]; then
    printf 'SKIP   %-45s excluded: %s\n' "$repo" "$reason"
    ok=$((ok + 1))
    continue
  fi

  state="$(gh api "repos/${repo}/immutable-releases" --jq '.enabled' 2>/dev/null)" || state=""
  if [ -z "$state" ]; then
    printf 'FAIL   %-45s could not read the immutable-releases setting\n' "$repo"
    failed=$((failed + 1))
    continue
  fi

  if [ "$state" = "true" ]; then
    printf 'SKIP   %-45s already enabled\n' "$repo"
    ok=$((ok + 1))
    continue
  fi

  if [ "$APPLY" -eq 0 ]; then
    printf 'PLAN   %-45s enable (currently disabled)\n' "$repo"
    ok=$((ok + 1))
    continue
  fi

  if gh api --method PUT "repos/${repo}/immutable-releases" >/dev/null 2>&1; then
    printf 'OK     %-45s enabled\n' "$repo"
    ok=$((ok + 1))
  else
    printf 'FAIL   %-45s PUT rejected\n' "$repo"
    failed=$((failed + 1))
  fi
done < "$REPOS_FILE"

printf '\nDONE   %s ok, %s failed\n' "$ok" "$failed"
[ "$failed" -eq 0 ]
