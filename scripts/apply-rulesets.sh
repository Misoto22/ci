#!/usr/bin/env bash
#
# Create or update the `main` repository ruleset on every repository listed in
# fleet/rulesets.json.
#
#   ./scripts/apply-rulesets.sh            # dry run (default)
#   ./scripts/apply-rulesets.sh --apply    # write
#
# The ruleset it writes:
#   target      branch, matching ~DEFAULT_BRANCH
#   enforcement active, bypass_actors []  (nobody bypasses, including the owner)
#   rules       deletion, non_fast_forward, pull_request, and
#               required_status_checks when fleet/rulesets.json lists any check
#
# `required_approving_review_count: 0` is deliberate: a solo account cannot
# approve its own pull request, so requiring one review would wedge every merge.
# The gate is the checks, not a second pair of eyes.
#
# Idempotency: the ruleset is looked up by name, then PUT in full. Running it
# twice is the same as running it once.
#
# Three things to know before --apply:
#   * Rulesets are additive to any classic branch protection already on the
#     repository; the most restrictive rule wins. This never weakens an existing
#     gate, but it does start requiring a pull request on repositories where
#     pushing straight to the default branch is the current habit.
#   * A required check name must match the rendered check exactly. A job inside
#     a reusable workflow renders as "<caller job id> / <called job name>", so
#     that whole string is the context — not the workflow file name.
#   * An update is a full replace, so a repository whose `main` ruleset already
#     requires checks that fleet/rulesets.json does not list would lose them.
#     That is a silent loss of branch protection, so the script fails closed: it
#     refuses the repository and says which contexts would have gone, unless
#     --allow-check-removal says the removal is intended.

set -euo pipefail

readonly RULESET_NAME="main"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
RULESETS_FILE="${REPO_ROOT}/fleet/rulesets.json"
APPLY=0
ALLOW_CHECK_REMOVAL=0

usage() {
  cat <<'USAGE'
Usage: apply-rulesets.sh [--apply] [--rulesets FILE] [--allow-check-removal]

  --apply                 Create or update the rulesets. Without it the script
                          prints the current state and the payload it would send.
  --rulesets FILE         Input map to use instead of fleet/rulesets.json.
  --allow-check-removal   Proceed even where the update would drop a required
                          status check the repository has today.
  -h, --help              This text.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --rulesets) shift; RULESETS_FILE="${1:?--rulesets needs a path}" ;;
    --allow-check-removal) ALLOW_CHECK_REMOVAL=1 ;;
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

if [ ! -f "$RULESETS_FILE" ]; then
  printf 'FATAL  ruleset map not found: %s\n' "$RULESETS_FILE" >&2
  exit 1
fi

if ! jq -e . "$RULESETS_FILE" >/dev/null 2>&1; then
  printf 'FATAL  %s is not valid JSON\n' "$RULESETS_FILE" >&2
  exit 1
fi

build_payload() {
  local checks_json="$1"
  jq -n --arg name "$RULESET_NAME" --argjson checks "$checks_json" '
    {
      name: $name,
      target: "branch",
      enforcement: "active",
      bypass_actors: [],
      conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
      rules: (
        [
          { type: "deletion" },
          { type: "non_fast_forward" },
          { type: "pull_request",
            parameters: {
              required_approving_review_count: 0,
              dismiss_stale_reviews_on_push: false,
              require_last_push_approval: false
            }
          }
        ]
        + (
          if ($checks | length) > 0 then
            [ { type: "required_status_checks",
                parameters: {
                  strict_required_status_checks_policy: true,
                  required_status_checks: ($checks | map({ context: . }))
                }
              } ]
          else
            []
          end
        )
      )
    }
  '
}

# Contexts the existing ruleset requires that the desired payload would not,
# as one comma-separated line (empty when nothing would be dropped).
dropped_checks() {
  local repo="$1" id="$2" checks_json="$3"
  gh api "repos/${repo}/rulesets/${id}" 2>/dev/null | jq -r --argjson desired "$checks_json" '
    (((.rules // [])
      | map(select(.type == "required_status_checks")
            | .parameters.required_status_checks // []
            | map(.context))
      | flatten)
     - $desired)
    | join(", ")
  '
}

summarise_existing() {
  local repo="$1" id="$2"
  gh api "repos/${repo}/rulesets/${id}" 2>/dev/null | jq -r '
    "enforcement=" + (.enforcement // "?")
    + " rules=[" + ((.rules // []) | map(.type) | sort | join(",")) + "]"
    + " checks=["
    + ((.rules // [])
       | map(select(.type == "required_status_checks")
             | .parameters.required_status_checks // []
             | map(.context))
       | flatten | join(", "))
    + "]"
  ' || printf 'could not read ruleset %s\n' "$id"
}

if [ "$APPLY" -eq 1 ]; then
  printf 'MODE   apply\n'
else
  printf 'MODE   dry-run (pass --apply to write)\n'
fi
printf 'INPUT  %s\n\n' "$RULESETS_FILE"

ok=0
failed=0
while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  checks_json="$(jq -c --arg r "$repo" '.[$r].checks // []' "$RULESETS_FILE")"

  if ! gh api "repos/${repo}" --silent >/dev/null 2>&1; then
    printf 'FAIL   %-45s repository not reachable\n' "$repo"
    failed=$((failed + 1))
    continue
  fi

  existing_id="$(gh api "repos/${repo}/rulesets" --jq \
    ".[] | select(.name == \"${RULESET_NAME}\") | .id" 2>/dev/null | head -n 1)"

  if [ -n "$existing_id" ]; then
    action="update"
  else
    action="create"
  fi

  payload="$(build_payload "$checks_json")"

  dropped=""
  if [ -n "$existing_id" ]; then
    dropped="$(dropped_checks "$repo" "$existing_id" "$checks_json")"
  fi

  if [ -n "$dropped" ] && [ "$ALLOW_CHECK_REMOVAL" -eq 0 ]; then
    printf 'BLOCK  %-45s would drop required checks: %s\n' "$repo" "$dropped"
    printf '       Add them to %s, or pass --allow-check-removal.\n' "$RULESETS_FILE"
    failed=$((failed + 1))
    continue
  fi
  if [ -n "$dropped" ]; then
    printf 'WARN   %-45s dropping required checks: %s\n' "$repo" "$dropped"
  fi

  if [ "$APPLY" -eq 0 ]; then
    printf 'PLAN   %-45s %s ruleset "%s"\n' "$repo" "$action" "$RULESET_NAME"
    if [ -n "$existing_id" ]; then
      printf '       current: %s\n' "$(summarise_existing "$repo" "$existing_id")"
    else
      printf '       current: no ruleset named "%s"\n' "$RULESET_NAME"
    fi
    printf '       desired: %s\n' \
      "$(printf '%s' "$payload" | jq -c '{enforcement, rules: (.rules | map(.type)), checks: ((.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks | map(.context)) // [])}')"
    ok=$((ok + 1))
    continue
  fi

  if [ -n "$existing_id" ]; then
    endpoint="repos/${repo}/rulesets/${existing_id}"
    method="PUT"
  else
    endpoint="repos/${repo}/rulesets"
    method="POST"
  fi

  if printf '%s' "$payload" |
     gh api --method "$method" "$endpoint" --input - >/dev/null 2>&1; then
    printf 'OK     %-45s %sd ruleset "%s"\n' "$repo" "$action" "$RULESET_NAME"
    ok=$((ok + 1))
  else
    printf 'FAIL   %-45s %s %s rejected\n' "$repo" "$method" "$endpoint"
    failed=$((failed + 1))
  fi
done < <(jq -r 'keys_unsorted[]' "$RULESETS_FILE")

printf '\nDONE   %s ok, %s failed\n' "$ok" "$failed"
[ "$failed" -eq 0 ]
