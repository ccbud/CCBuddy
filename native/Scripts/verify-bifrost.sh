#!/usr/bin/env bash
set -euo pipefail

readonly BINARY_PATH="${1:-}"
readonly REQUESTED_ARCHS="${2:-}"
readonly SHA256_ARM64="422eea68b860dd069d1b9989ff494a7bc566b7e11920632624cb6e85ca2c5263"
readonly SHA256_X86_64="50523247a6e5016bd3da29aeb0efea11e8ec6a01edd8b2b8b14bf4b6344afc07"

fail() { echo "$*" >&2; exit 1; }

if [[ -z "$BINARY_PATH" || ! -x "$BINARY_PATH" ]]; then
  fail "Missing executable Bifrost helper. Run native/Scripts/fetch-bifrost.sh first."
fi

ACTUAL_ARCHS="$(lipo -archs "$BINARY_PATH")"
readonly ACTUAL_ARCHS

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-bifrost-verify.XXXXXX")"
readonly WORK_DIR
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Checked one slice at a time rather than as a whole file. A universal helper is two published
# binaries joined by lipo, so it has a digest of its own that no upstream ever published and that
# nobody could pin; `lipo -thin` gives back the exact bytes that were downloaded, which are what
# the digests below are about.
expected_digest_for() {
  case "$1" in
    arm64) echo "$SHA256_ARM64" ;;
    x86_64) echo "$SHA256_X86_64" ;;
    *) fail "Unsupported or non-pinned Bifrost architecture: $1" ;;
  esac
}

for arch in $ACTUAL_ARCHS; do
  expected="$(expected_digest_for "$arch")"
  slice="$WORK_DIR/$arch"
  if [[ "$ACTUAL_ARCHS" == "$arch" ]]; then
    cp "$BINARY_PATH" "$slice"
  else
    lipo -thin "$arch" "$BINARY_PATH" -output "$slice"
  fi
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
