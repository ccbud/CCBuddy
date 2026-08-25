#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly APP_PATH="${1:-}"
readonly TIMEOUT_SECONDS="${2:-150}"

fail() { echo "packaged self-check failed: $*" >&2; exit 1; }

[[ -d "$APP_PATH" && "$(basename "$APP_PATH")" == "CC Buddy.app" ]] \
  || fail "usage: $0 <CC Buddy.app> [timeout-seconds]"
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "timeout must be a positive integer"
command -v jq >/dev/null || fail "jq is required"

readonly EXECUTABLE="$APP_PATH/Contents/MacOS/CC Buddy"
[[ -x "$EXECUTABLE" ]] || fail "app executable is missing"

SELF_CHECK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-packaged-selfcheck.XXXXXX")"
readonly SELF_CHECK_ROOT
readonly REPORT="$SELF_CHECK_ROOT/report.json"
readonly STANDARD_OUTPUT="$SELF_CHECK_ROOT/stdout.json"
readonly STANDARD_ERROR="$SELF_CHECK_ROOT/stderr.log"
SELF_CHECK_PID=""

cleanup() {
  if [[ -n "$SELF_CHECK_PID" ]] && kill -0 "$SELF_CHECK_PID" 2>/dev/null; then
    kill "$SELF_CHECK_PID" 2>/dev/null || true
  fi
  if [[ "${CCBUD_SELFCHECK_KEEP:-0}" == "1" ]]; then
    echo "kept self-check evidence: $SELF_CHECK_ROOT" >&2
  else
    rm -rf -- "$SELF_CHECK_ROOT"
  fi
}
trap cleanup EXIT INT TERM

CCBUD_SELFCHECK=1 \
CCBUD_HOME="$SELF_CHECK_ROOT" \
CCBUD_SELFCHECK_OUT="$REPORT" \
  "$EXECUTABLE" \
    -ApplePersistenceIgnoreState YES \
    -NSQuitAlwaysKeepsWindows NO \
    >"$STANDARD_OUTPUT" 2>"$STANDARD_ERROR" &
SELF_CHECK_PID=$!
readonly SELF_CHECK_PID

readonly DEADLINE=$((SECONDS + TIMEOUT_SECONDS))
while kill -0 "$SELF_CHECK_PID" 2>/dev/null; do
  if (( SECONDS >= DEADLINE )); then
    kill "$SELF_CHECK_PID" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$SELF_CHECK_PID" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$SELF_CHECK_PID" 2>/dev/null; then
      kill -9 "$SELF_CHECK_PID" 2>/dev/null || true
    fi
    wait "$SELF_CHECK_PID" 2>/dev/null || true
    fail "app exceeded ${TIMEOUT_SECONDS}s (stderr: $STANDARD_ERROR)"
  fi
  sleep 0.2
done

set +e
wait "$SELF_CHECK_PID"
readonly STATUS=$?
set -e
[[ "$STATUS" -eq 0 ]] || fail "app exited $STATUS (stderr: $STANDARD_ERROR)"

[[ -s "$REPORT" ]] || fail "report was not written"
[[ "$(stat -f '%Lp' "$REPORT")" == "600" ]] || fail "report mode is not 0600"
[[ "$(wc -l < "$REPORT" | tr -d ' ')" == "1" ]] || fail "report is not one line"
cmp -s "$REPORT" "$STANDARD_OUTPUT" || fail "stdout and the atomic report differ"

EXPECTED_VERSION="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
readonly EXPECTED_VERSION
jq -e --arg expectedVersion "$EXPECTED_VERSION" '
  .schema == "dev.ccbud.self-check"
  and .version == 1
  and .appVersion == $expectedVersion
  and .success == true
  and ([
    "main_bundle",
    "bundled_gateway",
    "config_atomic_round_trip",
    "history_round_trip",
    "clipboard_round_trip",
    "ui_snapshot",
    "gateway_lifecycle"
  ] - [.requiredChecks[].id] | length == 0)
  and all(.requiredChecks[]; .status == "passed")
' "$REPORT" >/dev/null || fail "required report contract did not pass"

if grep -Fq "$SELF_CHECK_ROOT" "$REPORT"; then
  fail "report leaked its isolated path"
fi
if pgrep -f "$SELF_CHECK_ROOT/gateway" >/dev/null 2>&1; then
  fail "an isolated ccbud-gateway process remains after app exit"
fi

echo "packaged self-check passed: $EXPECTED_VERSION"
