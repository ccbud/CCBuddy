#!/usr/bin/env bash
set -euo pipefail

readonly BIFROST_VERSION="v2.1.1"
readonly BIFROST_SHA256_ARM64="9a5dc7f02c28e2ec23207bfd6c54a3ee91c7a930b68ff6d2abddd738239ea971"
readonly BIFROST_SHA256_AMD64_UPSTREAM="540bf9f708de17a2d6b0c279a7f8c1498cd1bb23a5dbab8e6a357ce5072ca96c"
readonly BIFROST_SHA256_AMD64_NORMALIZED="76dc2cced55cef20485124d6a253d4753b614b1a6317c0fdd8d169e33137bc60"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
VENDOR_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/Vendor"
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

# Upstream cross-compiles the Intel Go binary on Ubuntu with MacOSX12.3.sdk, but its Mach-O load
# command incorrectly declares SDK 10.4. Apple rejects every notarization whose nested x86_64
# executable declares an SDK older than 10.9. Correct that SDK metadata to the actual 12.3 before
# Xcode signs it, while pinning both the downloaded bytes and the deterministic normalized result.
#
# The correction used to run through `xcrun vtool`, which re-emits the whole Mach-O and so could
# only ever be pinned by a digest produced on a Mac. normalize-macho-sdk.py edits the single SDK
# field in place instead: two bytes change, the result is reproducible on any platform, and
# verify-bifrost.sh still confirms the outcome independently with `vtool -show-build`.
normalize_intel_slice() {
  local upstream="$1"
  local destination="$2"
  local actual

  python3 "$SCRIPT_DIR/normalize-macho-sdk.py" --sdk 12.3 "$upstream" "$destination"
  chmod 0755 "$destination"
  actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
  [[ "$actual" == "$BIFROST_SHA256_AMD64_NORMALIZED" ]] \
    || fail "normalized Bifrost amd64 checksum mismatch: got $actual"
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
# Intel Mac on the legacy build with an updater that only knows how to fail.
if [[ "$REQUESTED" == "universal" ]]; then
  fetch_slice arm64 "$BIFROST_SHA256_ARM64" "$WORK_DIR/arm64"
  fetch_slice amd64 "$BIFROST_SHA256_AMD64_UPSTREAM" "$WORK_DIR/amd64-upstream"
  normalize_intel_slice "$WORK_DIR/amd64-upstream" "$WORK_DIR/amd64"
  lipo -create -output "$STAGED" "$WORK_DIR/arm64" "$WORK_DIR/amd64"
else
  if [[ "$REQUESTED" == "arm64" ]]; then
    fetch_slice arm64 "$BIFROST_SHA256_ARM64" "$STAGED"
  else
    fetch_slice amd64 "$BIFROST_SHA256_AMD64_UPSTREAM" "$WORK_DIR/amd64-upstream"
    normalize_intel_slice "$WORK_DIR/amd64-upstream" "$STAGED"
  fi
fi

chmod 0755 "$STAGED"
mv "$STAGED" "$OUTPUT_PATH"
echo "$OUTPUT_PATH"
