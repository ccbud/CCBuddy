#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
readonly MANIFEST="$ROOT/native/TgrepBridge/Cargo.toml"
readonly TARGET_DIR="$ROOT/native/TgrepBridge/target"
readonly OUTPUT="$ROOT/native/Vendor/libccbuddy_tgrep.dylib"
readonly REQUESTED_ARCH="${CCBUD_TGREP_ARCH:-$(uname -m)}"

command -v cargo >/dev/null || { echo "Rust stable is required to build the pinned tgrep library" >&2; exit 1; }
case "$REQUESTED_ARCH" in
  arm64|aarch64) targets=(aarch64-apple-darwin) ;;
  x86_64) targets=(x86_64-apple-darwin) ;;
  universal) targets=(aarch64-apple-darwin x86_64-apple-darwin) ;;
  *) echo "Unsupported tgrep architecture: $REQUESTED_ARCH" >&2; exit 1 ;;
esac

artifacts=()
for target in "${targets[@]}"; do
  # Install targets before signed-build credentials are imported. This script
  # never reads a developer checkout and Cargo.lock pins transitive packages.
  rustup target add "$target"
  # Include the deployment target in Rust's fingerprint as well as the linker
  # environment: changing only MACOSX_DEPLOYMENT_TARGET can reuse an older,
  # higher-minimum cached dylib without relinking it.
  MACOSX_DEPLOYMENT_TARGET=13.0 RUSTFLAGS='-C link-arg=-mmacosx-version-min=13.0' \
    cargo build --manifest-path "$MANIFEST" \
    --locked --release --target "$target" --target-dir "$TARGET_DIR"
  artifacts+=("$TARGET_DIR/$target/release/libccbuddy_tgrep.dylib")
done
mkdir -p "$ROOT/native/Vendor"
if [[ "${#artifacts[@]}" == 1 ]]; then
  cp "${artifacts[0]}" "$OUTPUT"
else
  lipo -create "${artifacts[@]}" -output "$OUTPUT"
fi
install_name_tool -id '@rpath/libccbuddy_tgrep.dylib' "$OUTPUT"
codesign --force --sign - "$OUTPUT"
lipo -info "$OUTPUT"
