#!/usr/bin/env bash
#
# Fan the misoto22-release-bot credentials out to every repository in
# fleet/repos.txt.
#
# A personal GitHub account has no account-level Actions secrets or variables,
# so the App private key and client ID have to exist in every consumer
# repository. That is the whole reason this script exists, and why it must stay
# idempotent: it is also the key-rotation procedure.
#
#   ./scripts/fanout-release-bot.sh            # dry run (default)
#   ./scripts/fanout-release-bot.sh --apply    # write
#
# The private key is read from 1Password straight into a shell variable and
# piped into `gh secret set`. It never touches disk, never reaches the terminal
# and never appears in an argument list.
#
# The key is read from the `private_key_b64` field, not `private_key`: 1Password
# re-wraps a multi-line password value in literal double quotes, so the raw
# field does not round-trip to the PEM that GitHub will accept. `private_key_b64`
# holds the same PEM base64-encoded on one line, which survives intact. Measured
# on 2026-09-17: the plain field renders 1680 bytes against the PEM's 1678, and
# the two differ by checksum.
#
# Prerequisites: `op` authenticated by the OP_SERVICE_ACCOUNT_TOKEN already
# exported in ~/.zshenv (never a biometric prompt, never `op signin`), `gh`
# logged in with admin rights on the target repositories, `jq`, and `base64`.

set -euo pipefail

readonly OP_ITEM="GitHub Release Bot App"
readonly OP_VAULT="01 Personal Development"
# 1Password field labels. Keep them free of spaces: `op read` on a spaced field
# label hangs on this machine with no output and no error.
readonly OP_FIELD_PRIVATE_KEY_B64="private_key_b64"
readonly OP_FIELD_CLIENT_ID="client_id"
readonly SECRET_NAME="APP_PRIVATE_KEY"
readonly VARIABLE_NAME="APP_CLIENT_ID"
# GNU coreutils `timeout` is not installed on this Mac, so every `op` call gets
# a hand-rolled watchdog instead. Without it a stuck `op` blocks forever.
readonly OP_TIMEOUT_SECONDS=20

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
REPOS_FILE="${REPO_ROOT}/fleet/repos.txt"
APPLY=0

usage() {
  cat <<'USAGE'
Usage: fanout-release-bot.sh [--apply] [--repos FILE]

  --apply        Write the secret and the variable. Without it the script only
                 reports what it would do.
  --repos FILE   Repository list to use instead of fleet/repos.txt.
  -h, --help     This text.
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

for tool in op gh jq base64; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL  %s is not installed\n' "$tool" >&2
    exit 1
  fi
done

if [ ! -f "$REPOS_FILE" ]; then
  printf 'FATAL  repository list not found: %s\n' "$REPOS_FILE" >&2
  exit 1
fi

# Run a command in the background and kill it after OP_TIMEOUT_SECONDS.
# The watchdog's own stdout is redirected away from the caller's pipe, or a
# command substitution would block for the full timeout even on success.
guarded() {
  local pid watchdog rc=0
  "$@" &
  pid=$!
  ( sleep "$OP_TIMEOUT_SECONDS"; kill -TERM "$pid" ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid" || rc=$?
  kill "$watchdog" >/dev/null 2>&1 || true
  wait "$watchdog" >/dev/null 2>&1 || true
  return "$rc"
}

# Does the 1Password item exist? Asked without --reveal so nothing sensitive is
# produced even into a discarded stream.
preflight_item() {
  local err rc=0
  err="$(guarded op item get "$OP_ITEM" --vault "$OP_VAULT" --format json 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; then
    printf 'FATAL  1Password timed out after %ss reading "%s" from vault "%s"\n' \
      "$OP_TIMEOUT_SECONDS" "$OP_ITEM" "$OP_VAULT" >&2
  elif printf '%s' "$err" | grep -qiE "isn'?t an item|not found|no item matches"; then
    printf 'FATAL  item not found: "%s" in vault "%s"\n' "$OP_ITEM" "$OP_VAULT" >&2
    printf '       Create it first, with fields %s and %s (labels without spaces).\n' \
      "$OP_FIELD_PRIVATE_KEY_B64" "$OP_FIELD_CLIENT_ID" >&2
  else
    printf 'FATAL  1Password read failed (exit %s)\n' "$rc" >&2
  fi
  if [ -n "$err" ]; then
    printf '       op said: %s\n' "$err" >&2
  fi
  return 1
}

# Print one field value on stdout. --format json keeps a multi-line PEM intact;
# the bare --fields renderer is not safe for multi-line values.
read_field() {
  local label="$1" rc=0 raw
  raw="$(guarded op item get "$OP_ITEM" --vault "$OP_VAULT" \
           --fields "label=${label}" --reveal --format json)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FATAL  could not read field "%s" from "%s" (exit %s)\n' \
      "$label" "$OP_ITEM" "$rc" >&2
    return 1
  fi
  printf '%s' "$raw" | jq -er 'if type == "array" then .[0].value else .value end'
}

# BSD base64 on older macOS spells the decode flag -D; GNU and current macOS
# both accept -d.
if printf '' | base64 -d >/dev/null 2>&1; then
  B64_DECODE=(base64 -d)
else
  B64_DECODE=(base64 -D)
fi

# The PEM must arrive byte-exact or every App token mint fails with an opaque
# error, so check its shape before touching any repository. Nothing about the
# key is printed beyond pass or fail.
valid_pem() {
  local pem="$1"
  case "$pem" in
    "-----BEGIN "*) ;;
    *) return 1 ;;
  esac
  case "$pem" in
    *'"'*) return 1 ;;
  esac
  printf '%s' "$pem" | tail -n 1 | grep -q -- '-----END '
}

PRIVATE_KEY=""
CLIENT_ID=""
CREDENTIALS_READY=0
if preflight_item; then
  private_key_b64="$(read_field "$OP_FIELD_PRIVATE_KEY_B64")" || private_key_b64=""
  if [ -n "$private_key_b64" ]; then
    PRIVATE_KEY="$(printf '%s' "$private_key_b64" | "${B64_DECODE[@]}")" || PRIVATE_KEY=""
  fi
  unset private_key_b64
  CLIENT_ID="$(read_field "$OP_FIELD_CLIENT_ID")" || CLIENT_ID=""

  if [ -z "$PRIVATE_KEY" ] || [ -z "$CLIENT_ID" ]; then
    printf 'FATAL  the 1Password item exists but a field is missing or empty\n' >&2
  elif ! valid_pem "$PRIVATE_KEY"; then
    printf 'FATAL  the decoded private key does not look like a PEM\n' >&2
    printf '       Expected a -----BEGIN … -----END block with no double quotes.\n' >&2
    printf '       Read the %s field, never %s: 1Password re-wraps a multi-line\n' \
      "$OP_FIELD_PRIVATE_KEY_B64" "private_key" >&2
    printf '       password value in literal double quotes.\n' >&2
  else
    CREDENTIALS_READY=1
    printf 'INFO   credentials read from 1Password (values not shown)\n'
  fi
fi

if [ "$APPLY" -eq 1 ] && [ "$CREDENTIALS_READY" -eq 0 ]; then
  printf 'FATAL  refusing to --apply without both credentials\n' >&2
  exit 1
fi

if [ "$APPLY" -eq 1 ]; then
  printf 'MODE   apply\n'
else
  printf 'MODE   dry-run (pass --apply to write)\n'
fi
printf 'LIST   %s\n\n' "$REPOS_FILE"

has_secret() {
  gh secret list --repo "$1" --json name --jq '.[].name' 2>/dev/null |
    grep -qx "$SECRET_NAME"
}

has_variable() {
  gh variable list --repo "$1" --json name --jq '.[].name' 2>/dev/null |
    grep -qx "$VARIABLE_NAME"
}

ok=0
failed=0
while IFS= read -r line || [ -n "$line" ]; do
  repo="${line%%#*}"
  repo="$(printf '%s' "$repo" | tr -d '[:space:]')"
  [ -z "$repo" ] && continue

  if ! gh api "repos/${repo}" --silent >/dev/null 2>&1; then
    printf 'FAIL   %-45s repository not reachable\n' "$repo"
    failed=$((failed + 1))
    continue
  fi

  if [ "$APPLY" -eq 0 ]; then
    secret_state=absent
    variable_state=absent
    has_secret "$repo" && secret_state=present
    has_variable "$repo" && variable_state=present
    printf 'PLAN   %-45s %s=%s %s=%s\n' \
      "$repo" "$SECRET_NAME" "$secret_state" "$VARIABLE_NAME" "$variable_state"
    ok=$((ok + 1))
    continue
  fi

  step_failed=0
  if ! printf '%s' "$PRIVATE_KEY" |
       gh secret set "$SECRET_NAME" --repo "$repo" >/dev/null 2>&1; then
    step_failed=1
  fi
  if ! gh variable set "$VARIABLE_NAME" --body "$CLIENT_ID" --repo "$repo" \
       >/dev/null 2>&1; then
    step_failed=1
  fi
  if [ "$step_failed" -eq 0 ]; then
    printf 'OK     %-45s %s + %s set\n' "$repo" "$SECRET_NAME" "$VARIABLE_NAME"
    ok=$((ok + 1))
  else
    printf 'FAIL   %-45s could not set the secret or the variable\n' "$repo"
    failed=$((failed + 1))
  fi
done < "$REPOS_FILE"

printf '\nDONE   %s ok, %s failed\n' "$ok" "$failed"
if [ "$failed" -gt 0 ] || [ "$CREDENTIALS_READY" -eq 0 ]; then
  exit 1
fi
