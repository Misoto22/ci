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
#   enforcement active
#   bypass      [] on a create — nobody bypasses, including the owner. On an
#               update the repository's current bypass_actors are read back and
#               sent again, unless --reset-bypass asks for the empty list.
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
# A repository whose fleet/rulesets.json entry carries "skip": true is reported
# and left untouched — for the repositories whose default-branch protection is
# owned somewhere else. Its "note" is printed as the reason.
#
# Four things to know before --apply:
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
#   * The replace covers bypass_actors too, and there is no equivalent warning
#     to print because a removed bypass shows up as nothing at all. So an update
#     carries the existing actors over verbatim rather than writing a literal
#     []. Clearing a bypass is a deliberate act and needs --reset-bypass.

set -euo pipefail

readonly RULESET_NAME="main"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
RULESETS_FILE="${REPO_ROOT}/fleet/rulesets.json"
APPLY=0
ALLOW_CHECK_REMOVAL=0
RESET_BYPASS=0

usage() {
  cat <<'USAGE'
Usage: apply-rulesets.sh [--apply] [--rulesets FILE] [--allow-check-removal]
                         [--reset-bypass]

  --apply                 Create or update the rulesets. Without it the script
                          prints the current state and the payload it would send.
  --rulesets FILE         Input map to use instead of fleet/rulesets.json.
  --allow-check-removal   Proceed even where the update would drop a required
                          status check the repository has today.
  --reset-bypass          Write bypass_actors [] on an update as well as on a
                          create, dropping any bypass the repository grants
                          today. Without it an update keeps what is there.
  -h, --help              This text.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --rulesets) shift; RULESETS_FILE="${1:?--rulesets needs a path}" ;;
    --allow-check-removal) ALLOW_CHECK_REMOVAL=1 ;;
    --reset-bypass) RESET_BYPASS=1 ;;
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
  local checks_json="$1" bypass_json="$2"
  jq -n --arg name "$RULESET_NAME" --argjson checks "$checks_json" \
        --argjson bypass "$bypass_json" '
    {
      name: $name,
      target: "branch",
      enforcement: "active",
      bypass_actors: $bypass,
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

# The bypass_actors of an existing ruleset, reduced to the three fields the API
# round-trips. Sending back a field GitHub adds later would risk a 422 on an
# otherwise unchanged list.
existing_bypass() {
  printf '%s' "$1" | jq -c '[.bypass_actors[]? | {actor_id, actor_type, bypass_mode}]'
}

# Contexts the existing ruleset requires that the desired payload would not,
# as one comma-separated line (empty when nothing would be dropped).
dropped_checks() {
  local existing_json="$1" checks_json="$2"
  printf '%s' "$existing_json" | jq -r --argjson desired "$checks_json" '
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
  printf '%s' "$1" | jq -r '
    "enforcement=" + (.enforcement // "?")
    + " rules=[" + ((.rules // []) | map(.type) | sort | join(",")) + "]"
    + " checks=["
    + ((.rules // [])
       | map(select(.type == "required_status_checks")
             | .parameters.required_status_checks // []
             | map(.context))
       | flatten | join(", "))
    + "]"
    + " bypass=["
    + ((.bypass_actors // [])
       | map((.actor_type // "?") + "/" + ((.actor_id // "?") | tostring)
             + "/" + (.bypass_mode // "?"))
       | join(", "))
    + "]"
  '
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

  if [ "$(jq -r --arg r "$repo" '.[$r].skip // false' "$RULESETS_FILE")" = "true" ]; then
    printf 'SKIP   %-45s %s\n' "$repo" \
      "$(jq -r --arg r "$repo" '.[$r].note // "\"skip\": true, no note"' "$RULESETS_FILE")"
    ok=$((ok + 1))
    continue
  fi

  checks_json="$(jq -c --arg r "$repo" '.[$r].checks // []' "$RULESETS_FILE")"

  if ! gh api "repos/${repo}" --silent >/dev/null 2>&1; then
    printf 'FAIL   %-45s repository not reachable\n' "$repo"
    failed=$((failed + 1))
    continue
  fi

  existing_id="$(gh api "repos/${repo}/rulesets" --jq \
    ".[] | select(.name == \"${RULESET_NAME}\") | .id" 2>/dev/null | head -n 1)"

  existing_json=""
  if [ -n "$existing_id" ]; then
    action="update"
    # One read answers all three questions about the ruleset being replaced:
    # what it enforces today, which required checks the replace would drop, and
    # which bypass actors have to survive it.
    existing_json="$(gh api "repos/${repo}/rulesets/${existing_id}" 2>/dev/null)" ||
      existing_json=""
    if ! printf '%s' "$existing_json" | jq -e . >/dev/null 2>&1; then
      printf 'FAIL   %-45s could not read ruleset %s; not replacing it unread\n' \
        "$repo" "$existing_id"
      failed=$((failed + 1))
      continue
    fi
  else
    action="create"
  fi

  bypass_json='[]'
  if [ -n "$existing_json" ] && [ "$RESET_BYPASS" -eq 0 ]; then
    bypass_json="$(existing_bypass "$existing_json")"
  fi

  payload="$(build_payload "$checks_json" "$bypass_json")"

  dropped=""
  if [ -n "$existing_json" ]; then
    dropped="$(dropped_checks "$existing_json" "$checks_json")"
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
    if [ -n "$existing_json" ]; then
      printf '       current: %s\n' "$(summarise_existing "$existing_json")"
    else
      printf '       current: no ruleset named "%s"\n' "$RULESET_NAME"
    fi
    printf '       desired: %s\n' \
      "$(printf '%s' "$payload" | jq -c '{enforcement, rules: (.rules | map(.type)), checks: ((.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks | map(.context)) // []), bypass: .bypass_actors}')"
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

  # Say so on the line itself: a carried-over bypass leaves no other trace.
  kept=""
  if [ "$bypass_json" != "[]" ]; then
    kept=" (kept $(printf '%s' "$bypass_json" | jq 'length') bypass actor(s))"
  fi

  if printf '%s' "$payload" |
     gh api --method "$method" "$endpoint" --input - >/dev/null 2>&1; then
    printf 'OK     %-45s %sd ruleset "%s"%s\n' \
      "$repo" "$action" "$RULESET_NAME" "$kept"
    ok=$((ok + 1))
  else
    printf 'FAIL   %-45s %s %s rejected\n' "$repo" "$method" "$endpoint"
    failed=$((failed + 1))
  fi
done < <(jq -r 'keys_unsorted[]' "$RULESETS_FILE")

printf '\nDONE   %s ok, %s failed\n' "$ok" "$failed"
[ "$failed" -eq 0 ]
