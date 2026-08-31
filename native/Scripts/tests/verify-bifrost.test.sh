#!/usr/bin/env bash
set -euo pipefail

# The helper is downloaded from a third party on every clean build, so the digests pinned in
# verify-bifrost.sh are the only thing between a release and whatever that host serves. A universal
# helper is two downloads joined by lipo and therefore has a digest nobody ever published, which is
# why the check is per-slice — and why it is worth proving that it still rejects a changed slice.
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
