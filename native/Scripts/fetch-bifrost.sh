#!/usr/bin/env bash
set -euo pipefail

readonly BIFROST_VERSION="v1.6.11"
readonly BIFROST_SHA256_ARM64="422eea68b860dd069d1b9989ff494a7bc566b7e11920632624cb6e85ca2c5263"
readonly BIFROST_SHA256_AMD64="50523247a6e5016bd3da29aeb0efea11e8ec6a01edd8b2b8b14bf4b6344afc07"
VENDOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Vendor"
readonly VENDOR_DIR
readonly OUTPUT_PATH="$VENDOR_DIR/bifrost-http"

fail() { echo "$*" >&2; exit 1; }

# Downloads one published slice and checks it against the digest pinned above. The upstream
# binaries are fetched over the network on every clean build, so the digest is the only thing
# standing between a release and whatever that host served today.
fetch_slice() {
  local arch="$1"
  local expected="$2"
  local destination="$3"
  local url="https://downloads.getmaxim.ai/bifrost/$BIFROST_VERSION/darwin/$arch/bifrost-http"
  local actual

  # `--retry-all-errors` because the interesting failure is a truncated transfer, which curl
  # reports as a completed request with a partial body rather than as a retryable status.
  curl --fail --location --retry 5 --retry-delay 2 --retry-all-errors \
    --output "$destination" "$url"
  actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "Bifrost $arch checksum mismatch: got $actual"
}

case "${CCBUD_BIFROST_ARCH:-$(uname -m)}" in
  arm64) readonly REQUESTED="arm64" ;;
  x86_64 | amd64) readonly REQUESTED="amd64" ;;
  universal) readonly REQUESTED="universal" ;;
  *) fail "Unsupported Bifrost architecture: ${CCBUD_BIFROST_ARCH:-$(uname -m)}" ;;
esac

mkdir -p "$VENDOR_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-bifrost.XXXXXX")"
readonly WORK_DIR
trap 'rm -rf -- "$WORK_DIR"' EXIT
readonly STAGED="$WORK_DIR/bifrost-http"

# A release ships one helper that runs on both kinds of Mac, so the two published slices are
# joined here rather than choosing between them. Building the arm64 slice alone would leave every
# Intel Mac still on 1.3.9 with an updater that only knows how to fail.
if [[ "$REQUESTED" == "universal" ]]; then
  fetch_slice arm64 "$BIFROST_SHA256_ARM64" "$WORK_DIR/arm64"
  fetch_slice amd64 "$BIFROST_SHA256_AMD64" "$WORK_DIR/amd64"
  lipo -create -output "$STAGED" "$WORK_DIR/arm64" "$WORK_DIR/amd64"
else
  if [[ "$REQUESTED" == "arm64" ]]; then
    fetch_slice arm64 "$BIFROST_SHA256_ARM64" "$STAGED"
  else
    fetch_slice amd64 "$BIFROST_SHA256_AMD64" "$STAGED"
  fi
fi

chmod 0755 "$STAGED"
mv "$STAGED" "$OUTPUT_PATH"
echo "$OUTPUT_PATH"
