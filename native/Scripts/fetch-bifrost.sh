#!/usr/bin/env bash
set -euo pipefail

readonly BIFROST_VERSION="v1.6.11"
readonly BIFROST_SHA256_ARM64="422eea68b860dd069d1b9989ff494a7bc566b7e11920632624cb6e85ca2c5263"
readonly BIFROST_SHA256_AMD64="50523247a6e5016bd3da29aeb0efea11e8ec6a01edd8b2b8b14bf4b6344afc07"
VENDOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Vendor"
readonly VENDOR_DIR
readonly OUTPUT_PATH="$VENDOR_DIR/bifrost-http"

case "${CCBUD_BIFROST_ARCH:-$(uname -m)}" in
  arm64) readonly BIFROST_ARCH="arm64"; readonly EXPECTED_SHA256="$BIFROST_SHA256_ARM64" ;;
  x86_64|amd64) readonly BIFROST_ARCH="amd64"; readonly EXPECTED_SHA256="$BIFROST_SHA256_AMD64" ;;
  *) echo "Unsupported Bifrost architecture: ${CCBUD_BIFROST_ARCH:-$(uname -m)}" >&2; exit 1 ;;
esac

mkdir -p "$VENDOR_DIR"
readonly DOWNLOAD_URL="https://downloads.getmaxim.ai/bifrost/$BIFROST_VERSION/darwin/$BIFROST_ARCH/bifrost-http"
readonly TEMP_PATH="$OUTPUT_PATH.download"
trap 'rm -f "$TEMP_PATH"' EXIT
curl --fail --location --retry 3 --output "$TEMP_PATH" "$DOWNLOAD_URL"
ACTUAL_SHA256="$(shasum -a 256 "$TEMP_PATH" | awk '{print $1}')"
readonly ACTUAL_SHA256
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "Bifrost checksum mismatch: got $ACTUAL_SHA256" >&2
  exit 1
fi
chmod 0755 "$TEMP_PATH"
mv "$TEMP_PATH" "$OUTPUT_PATH"
echo "$OUTPUT_PATH"
