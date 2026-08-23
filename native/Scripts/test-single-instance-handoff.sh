#!/usr/bin/env bash
set -euo pipefail

readonly APP_PATH="${1:-}"
readonly TIMEOUT_SECONDS="${2:-15}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT

fail() { echo "single-instance handoff failed: $*" >&2; exit 1; }

[[ -d "$APP_PATH" && "$(basename "$APP_PATH")" == "CC Buddy.app" ]] \
  || fail "usage: $0 <CC Buddy.app> [timeout-seconds]"
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "timeout must be a positive integer"
command -v xcrun >/dev/null || fail "xcrun is required"
command -v ditto >/dev/null || fail "ditto is required"

PROBE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-instance-probe.XXXXXX")"
readonly PROBE_ROOT
readonly PROBE_APP="$PROBE_ROOT/CC Buddy.app"
cleanup() {
  if [[ "${CCBUD_HANDOFF_KEEP:-0}" == 1 ]]; then
    echo "kept single-instance evidence: $PROBE_ROOT" >&2
  else
    rm -rf -- "$PROBE_ROOT"
  fi
}
trap cleanup EXIT INT TERM

ditto "$APP_PATH" "$PROBE_APP"
PROBE_SUFFIX="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
readonly PROBE_SUFFIX
/usr/libexec/PlistBuddy -c \
  "Set :CFBundleIdentifier dev.ccbud.gateway.handoff.probe${PROBE_SUFFIX}" \
  "$PROBE_APP/Contents/Info.plist"

xcrun swift "$ROOT/test-single-instance-handoff.swift" "$PROBE_APP" "$TIMEOUT_SECONDS"
