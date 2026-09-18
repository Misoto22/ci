#!/usr/bin/env bash
#
# Make every squash merge in fleet/repos.txt default its commit subject to the
# pull request's title, and its commit body to the pull request's description.
#
#   ./scripts/set-squash-merge-title.sh            # dry run (default)
#   ./scripts/set-squash-merge-title.sh --apply    # write
#
# Why PR_TITLE: `pr-title / pr-title` validates the pull request's title, and
# release-please parses the commit subject that lands on the default branch.
# GitHub's default, squash_merge_commit_title=COMMIT_OR_PR_TITLE, only makes
# the two the same thing when the pull request has more than one commit. A
# single-commit pull request lands that commit's own subject, which nothing
# validated. servo-map #20 is the evidence: it passed pr-title as
# "chore: bump the actions group …" and landed as ef2f7d0
# "chore: Bump the actions group …" (#20), Dependabot's original commit
# subject. Dependabot then copies the case of that last Dependabot commit into
# every later title, so the next one fails pr-title again. PR_TITLE lands the
# validated title every time.
#
# Why PR_BODY, not COMMIT_MESSAGES: pairing PR_TITLE with
# squash_merge_commit_message=COMMIT_MESSAGES put the original commit's full
# message in the squash body. On a single-commit PR that message's own first
# line is a conventional-commit header in its own right, and release-please
# parses it as a second change. zhaojian's 672c96c is the evidence: subject
# "fix(deploy): reach Dokploy at the origin to bypass the Cloudflare bot
# challenge (#120)", body first line "fix(deploy): reach Dokploy at the origin
# past Cloudflare". release-please's PR #116 changelog listed both as separate
# Bug Fixes entries for one change. PR_BODY makes the squash body the PR
# description instead, which keeps the rationale in history without holding a
# second conventional header — see "The squash subject must be the PR title"
# in the README for the caution that applies to writing that description.
#
#   PATCH /repos/{owner}/{repo}
#     squash_merge_commit_title=PR_TITLE
#     squash_merge_commit_message=PR_BODY
#
# The REST API requires squash_merge_commit_title whenever
# squash_merge_commit_message is sent, so the two always go together.
# PR_TITLE+PR_BODY is one of GitHub's documented valid pairs, so no fallback
# is attempted if the API rejects it; the line reports the failure instead.
#
# A repository that does not allow squash merging (harness merges with merge
# commits only) is reported as SKIP and never written to: the setting would
# have no effect there. Every write is confirmed by reading the repository back
# with a fresh GET, not by trusting the PATCH's exit code.
#
# The authenticated gh user needs admin access on the repository.

set -euo pipefail

readonly WANT_TITLE="PR_TITLE"
readonly WANT_MESSAGE="PR_BODY"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
REPOS_FILE="${REPO_ROOT}/fleet/repos.txt"
APPLY=0

usage() {
  cat <<'USAGE'
Usage: set-squash-merge-title.sh [--apply] [--repos FILE]

  --apply         Set squash_merge_commit_title=PR_TITLE and
                  squash_merge_commit_message=PR_BODY on every repository
                  that allows squash merging. Without it the script only
                  reports what it would do.
  --repos FILE    Repository list to use instead of fleet/repos.txt.
  -h, --help      This text.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --repos) shift; REPOS_FILE="${1:?--repos needs a path}" ;;
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

# The three settings this script reads, as one tab-separated line:
# allow_squash_merge, squash_merge_commit_title, squash_merge_commit_message.
# A field the API leaves out (a token without admin access) prints as "null".
squash_settings() {
  gh api "repos/$1" --jq '[
    (.allow_squash_merge | tostring),
    (.squash_merge_commit_title // "null"),
    (.squash_merge_commit_message // "null")
  ] | join("\t")'
}

# PATCH the pair and print the API's error text on failure. The response body
# is discarded: the caller confirms with a fresh GET.
patch_squash() {
  {
    gh api --method PATCH "repos/$1" \
      -f squash_merge_commit_title="$WANT_TITLE" \
      -f squash_merge_commit_message="$WANT_MESSAGE" >/dev/null
  } 2>&1
}

if [ "$APPLY" -eq 1 ]; then
  printf 'MODE   apply\n'
else
  printf 'MODE   dry-run (pass --apply to write)\n'
fi
printf 'LIST   %s\n\n' "$REPOS_FILE"

ok=0
failed=0
while IFS= read -r line || [ -n "$line" ]; do
  repo="${line%%#*}"
  repo="$(printf '%s' "$repo" | tr -d '[:space:]')"
  [ -z "$repo" ] && continue

  if ! current="$(squash_settings "$repo" 2>/dev/null)"; then
    printf 'FAIL   %-45s could not read the repository settings\n' "$repo"
    failed=$((failed + 1))
    continue
  fi
  IFS=$'\t' read -r allow title message <<<"$current"

  if [ "$allow" != "true" ]; then
    printf 'SKIP   %-45s squash merging is off (allow_squash_merge=%s); the title setting would have no effect\n' \
      "$repo" "$allow"
    ok=$((ok + 1))
    continue
  fi

  if [ "$title" = "null" ] || [ "$message" = "null" ]; then
    printf 'FAIL   %-45s squash settings not readable (title=%s message=%s); admin access needed\n' \
      "$repo" "$title" "$message"
    failed=$((failed + 1))
    continue
  fi

  if [ "$title" = "$WANT_TITLE" ] && [ "$message" = "$WANT_MESSAGE" ]; then
    printf 'SKIP   %-45s already squash_merge_commit_title=%s message=%s\n' \
      "$repo" "$title" "$message"
    ok=$((ok + 1))
    continue
  fi

  if [ "$APPLY" -eq 0 ]; then
    printf 'PLAN   %-45s title %s -> %s, message %s -> %s\n' \
      "$repo" "$title" "$WANT_TITLE" "$message" "$WANT_MESSAGE"
    ok=$((ok + 1))
    continue
  fi

  if ! error="$(patch_squash "$repo")"; then
    printf 'FAIL   %-45s PATCH rejected: %s\n' "$repo" \
      "$(printf '%s' "$error" | tr '\n' ' ' | tr -s ' ')"
    failed=$((failed + 1))
    continue
  fi

  # Confirm with a fresh read: an ignored field would come back unchanged
  # behind a 200.
  if after="$(squash_settings "$repo" 2>/dev/null)"; then
    IFS=$'\t' read -r _ after_title after_message <<<"$after"
  else
    after_title="unreadable"
    after_message="unreadable"
  fi
  if [ "$after_title" = "$WANT_TITLE" ] && [ "$after_message" = "$WANT_MESSAGE" ]; then
    printf 'OK     %-45s title %s -> %s, message %s -> %s\n' \
      "$repo" "$title" "$after_title" "$message" "$after_message"
    ok=$((ok + 1))
  else
    printf 'FAIL   %-45s read back title=%s message=%s, wanted %s/%s\n' \
      "$repo" "$after_title" "$after_message" "$WANT_TITLE" "$WANT_MESSAGE"
    failed=$((failed + 1))
  fi
done < "$REPOS_FILE"

printf '\nDONE   %s ok, %s failed\n' "$ok" "$failed"
[ "$failed" -eq 0 ]
