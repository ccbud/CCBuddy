#!/usr/bin/env bash
set -euo pipefail

# The helper is downloaded from a third party on every clean build. fetch-bifrost pins the raw
# downloads, while verify-bifrost pins the arm64 slice and the notarization-compatible Intel
# normalization. A universal helper has no upstream digest of its own, which is why the check is
# per-slice — and why it is worth proving that it still rejects a changed slice.
#
# Everything below runs against the real vendored helper. There is no digest override to test
# through: a switch that let a build accept unpinned bytes would defeat the check it is testing.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly ROOT
readonly VERIFY="$ROOT/native/Scripts/verify-bifrost.sh"
readonly HELPER="$ROOT/native/Vendor/bifrost-http"

PASSED=0
fail() { echo "verify-bifrost validator test failed: $*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); echo "ok $PASSED - $1"; }

expect_pass() {
  local description="$1"
  shift
  "$VERIFY" "$@" >/dev/null 2>&1 || fail "$description"
  ok "$description"
}

expect_fail() {
  local description="$1"
  shift
  if "$VERIFY" "$@" >/dev/null 2>&1; then fail "$description"; fi
  ok "$description"
}

expect_fail_with_message() {
  local description="$1"
  local message="$2"
  shift 2
  local error="$WORK/error-$PASSED"
  if "$VERIFY" "$@" >/dev/null 2>"$error"; then fail "$description"; fi
  grep -Fq "$message" "$error" || fail "$description did not report: $message"
  ok "$description"
}

[[ "$(uname -s)" == Darwin ]] || fail "macOS is required for lipo"
[[ -x "$VERIFY" || -f "$VERIFY" ]] || fail "verify-bifrost.sh is missing"
[[ -x "$HELPER" ]] || fail "run native/Scripts/fetch-bifrost.sh first"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-bifrost-test.XXXXXX")"
readonly WORK
trap 'rm -rf -- "$WORK"' EXIT

ARCHS="$(lipo -archs "$HELPER")"
readonly ARCHS
for required in arm64 x86_64; do
  case " $ARCHS " in
    *" $required "*) ;;
    *) fail "the vendored helper is $ARCHS; a release helper carries both slices" ;;
  esac
done
ok "the vendored helper is universal"

expect_pass "a universal helper satisfies a request for both slices" "$HELPER" "arm64 x86_64"
expect_pass "a universal helper satisfies an arm64-only debug build" "$HELPER" "arm64"
expect_pass "a universal helper satisfies an x86_64-only build" "$HELPER" "x86_64"
expect_pass "no requested architectures is not an error" "$HELPER" ""

# A single-slice helper is still a valid local build input, but it cannot satisfy a release.
readonly THIN="$WORK/thin-arm64"
lipo -thin arm64 "$HELPER" -output "$THIN"
chmod 0755 "$THIN"
expect_pass "a thinned arm64 helper still passes its own digest" "$THIN" "arm64"
expect_fail "a thinned arm64 helper cannot satisfy a universal release" "$THIN" "arm64 x86_64"

# Apple refuses a signed app when any nested x86_64 executable declares an SDK older than 10.9.
# The pinned upstream Intel helper says 10.4, so fetch-bifrost normalizes it before this validator
# accepts the post-normalization digest.
readonly INTEL="$WORK/thin-x86_64"
lipo -thin x86_64 "$HELPER" -output "$INTEL"
chmod 0755 "$INTEL"
expect_pass "the normalized Intel helper passes its digest and SDK gate" "$INTEL" "x86_64"
arch -x86_64 "$INTEL" --help >/dev/null 2>&1 \
  || fail "the normalized Intel helper does not launch"
ok "the normalized Intel helper still launches after load-command normalization"
readonly OLD_SDK="$WORK/old-sdk-x86_64"
xcrun vtool -set-version-min macos 10.4 10.4 -replace \
  -output "$OLD_SDK" "$INTEL"
chmod 0755 "$OLD_SDK"
expect_fail_with_message "an Intel helper with the rejected SDK is refused before signing" \
  "SDK 10.4 is older than Apple's notarization minimum 10.9" "$OLD_SDK" "x86_64"

# One byte, inside one slice. The whole-file digest of a universal binary is not pinned anywhere,
# so this is the case that a naive check would wave through.
readonly TAMPERED="$WORK/tampered"
cp "$HELPER" "$TAMPERED"
SIZE="$(stat -f%z "$TAMPERED")"
readonly SIZE
printf '\xff' | dd of="$TAMPERED" bs=1 seek=$((SIZE - 4096)) count=1 conv=notrunc status=none
chmod 0755 "$TAMPERED"
expect_fail "a single altered byte in one slice is rejected" "$TAMPERED" "arm64 x86_64"

# A real, correctly shaped universal Mach-O that simply is not the helper. /bin/echo ships with
# both slices, so it passes every structural check and fails only on the digests.
readonly IMPOSTOR="$WORK/impostor"
cp /bin/echo "$IMPOSTOR"
chmod 0755 "$IMPOSTOR"
expect_fail "an unrelated binary with the right architectures is rejected" "$IMPOSTOR" "arm64"

expect_fail "a missing helper is reported rather than skipped" "$WORK/absent" "arm64"
expect_fail "an architecture the helper does not carry is refused" "$THIN" "x86_64"
expect_fail "an unpinned architecture is refused" "$HELPER" "arm64e"

echo "verified $PASSED Bifrost helper validator cases"
