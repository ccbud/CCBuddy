#!/usr/bin/env bash
set -euo pipefail

readonly BINARY_PATH="${1:-}"
readonly REQUESTED_ARCHS="${2:-}"
readonly SHA256_ARM64="422eea68b860dd069d1b9989ff494a7bc566b7e11920632624cb6e85ca2c5263"
readonly SHA256_X86_64="50523247a6e5016bd3da29aeb0efea11e8ec6a01edd8b2b8b14bf4b6344afc07"

if [[ -z "$BINARY_PATH" || ! -x "$BINARY_PATH" ]]; then
  echo "Missing executable Bifrost helper. Run native/Scripts/fetch-bifrost.sh first." >&2
  exit 1
fi

ACTUAL_ARCHS="$(lipo -archs "$BINARY_PATH")"
readonly ACTUAL_ARCHS
case "$ACTUAL_ARCHS" in
  arm64) readonly EXPECTED_SHA256="$SHA256_ARM64" ;;
  x86_64) readonly EXPECTED_SHA256="$SHA256_X86_64" ;;
  *) echo "Unsupported or non-pinned Bifrost architecture set: $ACTUAL_ARCHS" >&2; exit 1 ;;
esac

ACTUAL_SHA256="$(shasum -a 256 "$BINARY_PATH" | awk '{print $1}')"
readonly ACTUAL_SHA256
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "Bifrost checksum mismatch: got $ACTUAL_SHA256" >&2
  exit 1
fi

for requested in $REQUESTED_ARCHS; do
  if [[ "$ACTUAL_ARCHS" != "$requested" ]]; then
    echo "Bifrost helper is $ACTUAL_ARCHS but the app target requests $requested" >&2
    exit 1
  fi
done
