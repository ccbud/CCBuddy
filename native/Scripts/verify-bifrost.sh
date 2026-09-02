#!/usr/bin/env bash
set -euo pipefail

readonly BINARY_PATH="${1:-}"
readonly REQUESTED_ARCHS="${2:-}"
readonly SHA256_ARM64="422eea68b860dd069d1b9989ff494a7bc566b7e11920632624cb6e85ca2c5263"
readonly SHA256_X86_64="cff62f56fc2bb8274f0b5eb97e663d6d1db953fcd710bb9ef9add1b7d27f75b3"

fail() { echo "$*" >&2; exit 1; }

if [[ -z "$BINARY_PATH" || ! -x "$BINARY_PATH" ]]; then
  fail "Missing executable Bifrost helper. Run native/Scripts/fetch-bifrost.sh first."
fi

ACTUAL_ARCHS="$(lipo -archs "$BINARY_PATH")"
readonly ACTUAL_ARCHS

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-bifrost-verify.XXXXXX")"
readonly WORK_DIR
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Checked one slice at a time rather than as a whole file. A universal helper is two binaries
# joined by lipo, so it has a digest of its own that no upstream ever published. `lipo -thin`
# recovers the pinned arm64 download and the pinned, notarization-compatible Intel normalization.
expected_digest_for() {
  case "$1" in
    arm64) echo "$SHA256_ARM64" ;;
    x86_64) echo "$SHA256_X86_64" ;;
    *) fail "Unsupported or non-pinned Bifrost architecture: $1" ;;
  esac
}

require_notarizable_sdk() {
  local arch="$1"
  local slice="$2"
  local sdk major minor
  sdk="$(xcrun vtool -show-build "$slice" | awk '$1 == "sdk" {print $2; exit}')"
  [[ "$sdk" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]] \
    || fail "Bifrost $arch has no valid macOS SDK load command"
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  if (( major < 10 || (major == 10 && minor < 9) )); then
    fail "Bifrost $arch SDK $sdk is older than Apple's notarization minimum 10.9"
  fi
}

for arch in $ACTUAL_ARCHS; do
  slice="$WORK_DIR/$arch"
  if [[ "$ACTUAL_ARCHS" == "$arch" ]]; then
    cp "$BINARY_PATH" "$slice"
  else
    lipo -thin "$arch" "$BINARY_PATH" -output "$slice"
  fi
  require_notarizable_sdk "$arch" "$slice"
  expected="$(expected_digest_for "$arch")"
  actual="$(shasum -a 256 "$slice" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "Bifrost $arch checksum mismatch: got $actual"
done

# The app may ask for fewer architectures than the helper carries — a local arm64-only debug build
# against a universal helper is fine — but never for one the helper does not have.
for requested in $REQUESTED_ARCHS; do
  case " $ACTUAL_ARCHS " in
    *" $requested "*) ;;
    *) fail "Bifrost helper is $ACTUAL_ARCHS but the app target requests $requested" ;;
  esac
done
