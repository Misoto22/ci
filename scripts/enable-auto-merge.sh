#!/usr/bin/env bash
#
# Turn on "Allow auto-merge" for every repository in fleet/repos.txt whose
# default branch already requires a real status check.
#
#   ./scripts/enable-auto-merge.sh            # dry run (default)
#   ./scripts/enable-auto-merge.sh --apply    # write
#
# The repository setting `allow_auto_merge` is the per-repository opt-in switch
# for the reusable release.yml: its last step enables auto-merge on the bot's
# release PR only where this setting is on AND the target branch requires at
# least one status check besides `pr-title / pr-title`. That second condition
# is checked here too, before the setting is written: pr-title passes the
# moment a PR opens, so on a branch that requires nothing else a release PR
# would merge before any build ran.
#
# A repository that fails the check is reported as SKIP with the reason and is
# never written to. The script only ever turns the setting on; a repository
# that already allows auto-merge without a real check keeps it (someone may use
# it by hand), and the workflow's own check still refuses its release PRs.
#
#   PATCH /repos/{owner}/{repo}  allow_auto_merge=true
#
# The authenticated gh user needs admin access on the repository.
#
# Repositories listed in fleet/auto-merge-exclude.txt are reported as SKIP with
# their reason and never written to. The list is required: a missing file is
# fatal rather than an empty exclusion. Pass --exclude /dev/null to exclude
# nothing on purpose.

set -euo pipefail

readonly IGNORED_CONTEXT='pr-title / pr-title'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
REPOS_FILE="${REPO_ROOT}/fleet/repos.txt"
EXCLUDE_FILE="${REPO_ROOT}/fleet/auto-merge-exclude.txt"
APPLY=0

usage() {
  cat <<'USAGE'
Usage: enable-auto-merge.sh [--apply] [--repos FILE] [--exclude FILE]

  --apply         Set allow_auto_merge=true where the default branch requires a
                  status check besides `pr-title / pr-title`. Without it the
                  script only reports what it would do.
  --repos FILE    Repository list to use instead of fleet/repos.txt.
  --exclude FILE  Exclusion list to use instead of fleet/auto-merge-exclude.txt.
                  Pass /dev/null to exclude nothing.
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

for tool in gh jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL  %s is not installed\n' "$tool" >&2
    exit 1
  fi
done

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
# A line is `owner/name` with an optional reason after a `#`; a whole-line
# comment carries no repository name and so can never match.
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

# --- keep merge_method and required_contexts identical to the "Enable
# --- auto-merge on the release PR" step of .github/workflows/release.yml. That
# --- step runs in the caller's checkout, so it cannot source this script.

# Print the flag `gh pr merge` takes for this repository: squash when
# the repository allows it, else a merge commit, else rebase.
merge_method() {
  printf '%s' "$1" | jq -r '
    if .allow_squash_merge == true then "squash"
    elif .allow_merge_commit == true then "merge"
    else "rebase" end'
}

# Set REQUIRED_CONTEXTS to the status checks BRANCH requires, one per
# line, sorted, without IGNORED_CONTEXT: the union of the active
# rulesets and classic branch protection. Set CLASSIC_STATE to where
# the classic half came from: `protection` (the protection endpoint),
# `branch` (the branch endpoint's summary, used when the protection
# endpoint refuses a token without Administration read), `none` (no
# classic protection) or `unreadable`. Return 1 when the rulesets
# themselves could not be read.
required_contexts() {
  local repo="$1" branch="$2" rules classic="" body status
  REQUIRED_CONTEXTS=""
  CLASSIC_STATE="unreadable"
  rules="$(gh api --paginate "repos/${repo}/rules/branches/${branch}" --jq '
    .[] | select(.type == "required_status_checks")
    | .parameters.required_status_checks[].context' 2>/dev/null)" || return 1
  if body="$(gh api "repos/${repo}/branches/${branch}/protection/required_status_checks" \
      --jq '(.contexts // [])[], ((.checks // [])[] | .context)' 2>/dev/null)"; then
    classic="$body"
    CLASSIC_STATE="protection"
  else
    # On an HTTP error gh prints the error document on stdout; its
    # status separates an unprotected branch (404) from a token that
    # may not look (403).
    status="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null)" || status=""
    if [ "$status" = "404" ]; then
      CLASSIC_STATE="none"
    elif body="$(gh api "repos/${repo}/branches/${branch}" --jq '
        .protection.required_status_checks // {}
        | select(.enforcement_level != "off") | (.contexts // [])[]' 2>/dev/null)"; then
      classic="$body"
      CLASSIC_STATE="branch"
    fi
  fi
  REQUIRED_CONTEXTS="$(printf '%s\n%s\n' "$rules" "$classic" |
    grep -vxF -e "$IGNORED_CONTEXT" -e '' | sort -u)" || REQUIRED_CONTEXTS=""
}

# --- end of the shared functions

# One line for a PLAN/SKIP row. Contexts can themselves contain commas
# ("format, lint, types, tests (Python 3.14)"), so they are joined with "; ".
join_contexts() {
  printf '%s\n' "$1" | awk 'NF { if (n++) printf "; "; printf "%s", $0 }'
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

  if ! repo_json="$(gh api "repos/${repo}" 2>/dev/null)"; then
    printf 'FAIL   %-45s could not read the repository settings\n' "$repo"
    failed=$((failed + 1))
    continue
  fi
  branch="$(printf '%s' "$repo_json" | jq -r '.default_branch')"
  allow="$(printf '%s' "$repo_json" | jq -r '.allow_auto_merge')"
  method="$(merge_method "$repo_json")"

  if ! required_contexts "$repo" "$branch"; then
    printf 'FAIL   %-45s could not read the rulesets on %s\n' "$repo" "$branch"
    failed=$((failed + 1))
    continue
  fi

  if [ -z "$REQUIRED_CONTEXTS" ]; then
    kept=""
    if [ "$allow" = "true" ]; then
      kept="; allow_auto_merge is already true and is left as it is, the release workflow still refuses"
    fi
    printf 'SKIP   %-45s %s requires no status check besides %s (classic: %s)%s\n' \
      "$repo" "$branch" "$IGNORED_CONTEXT" "$CLASSIC_STATE" "$kept"
    ok=$((ok + 1))
    continue
  fi

  detail="checks on ${branch}: $(join_contexts "$REQUIRED_CONTEXTS") (classic: ${CLASSIC_STATE}); merge --${method}"

  if [ "$allow" = "true" ]; then
    printf 'SKIP   %-45s already enabled; %s\n' "$repo" "$detail"
    ok=$((ok + 1))
    continue
  fi

  if [ "$APPLY" -eq 0 ]; then
    printf 'PLAN   %-45s enable (allow_auto_merge=%s); %s\n' "$repo" "$allow" "$detail"
    ok=$((ok + 1))
    continue
  fi

  # Read the value back from the PATCH response rather than trusting the exit
  # code: an ignored field would come back unchanged with a 200.
  if after="$(gh api --method PATCH "repos/${repo}" -F allow_auto_merge=true \
                --jq '.allow_auto_merge' 2>&1)" && [ "$after" = "true" ]; then
    printf 'OK     %-45s enabled; %s\n' "$repo" "$detail"
    ok=$((ok + 1))
  else
    printf 'FAIL   %-45s PATCH did not take (allow_auto_merge=%s)\n' "$repo" \
      "$(printf '%s' "$after" | tr '\n' ' ' | tr -s ' ')"
    failed=$((failed + 1))
  fi
done < "$REPOS_FILE"

printf '\nDONE   %s ok, %s failed\n' "$ok" "$failed"
[ "$failed" -eq 0 ]
