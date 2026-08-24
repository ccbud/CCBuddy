#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
readonly ROOT
readonly SOURCE_HELPER="$ROOT/native/Vendor/ccbud-gateway"
readonly VERIFIER="$ROOT/native/Scripts/verify-gateway-helper.sh"

fail() { echo "gateway helper verifier test failed: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required"
[[ "$(uname -m)" == "arm64" ]] || fail "an Apple-silicon host is required"
[[ -x "$SOURCE_HELPER" ]] || fail "build the gateway helper before running this test"
[[ -x "$VERIFIER" ]] || fail "gateway helper verifier is not executable"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-gateway-verifier-test.XXXXXX")"
readonly TEST_ROOT
trap 'rm -rf -- "$TEST_ROOT"' EXIT INT TERM HUP
readonly FIXTURE_DIRECTORY="$TEST_ROOT/CC Buddy fixture"
readonly FIXTURE_HELPER="$FIXTURE_DIRECTORY/ccbud gateway"
mkdir -p "$FIXTURE_DIRECTORY"
install -m 0755 "$SOURCE_HELPER" "$FIXTURE_HELPER"

EXPECTED_IDENTITY="$("$SOURCE_HELPER" --version)"
readonly EXPECTED_IDENTITY
ACTUAL_OUTPUT="$("$VERIFIER" "$FIXTURE_HELPER" arm64)"
readonly ACTUAL_OUTPUT
readonly EXPECTED_OUTPUT="verified arm64 $EXPECTED_IDENTITY: $FIXTURE_HELPER"
[[ "$ACTUAL_OUTPUT" == "$EXPECTED_OUTPUT" ]] \
  || fail "unexpected verifier output: $ACTUAL_OUTPUT"

echo "verified gateway helper paths containing spaces"
