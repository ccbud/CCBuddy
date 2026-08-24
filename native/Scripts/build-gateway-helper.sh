#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
readonly HELPER_ROOT="$ROOT/native/GatewayHelper"
readonly MANIFEST="$HELPER_ROOT/Cargo.toml"
readonly LOCKFILE="$HELPER_ROOT/Cargo.lock"
readonly BUILD_OUTPUT="$HELPER_ROOT/target/release/ccbud-gateway"
readonly VENDOR_DIR="$ROOT/native/Vendor"
readonly OUTPUT="$VENDOR_DIR/ccbud-gateway"

fail() { echo "gateway helper build failed: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required"
[[ "$(uname -m)" == "arm64" ]] || fail "an Apple-silicon host is required"
[[ -f "$MANIFEST" ]] || fail "missing manifest: $MANIFEST"
[[ -f "$LOCKFILE" ]] || fail "missing lockfile: $LOCKFILE"
command -v cargo >/dev/null || fail "cargo is required"
command -v rustc >/dev/null || fail "rustc is required"

RUST_HOST="$(rustc -vV | sed -n 's/^host: //p')"
readonly RUST_HOST
[[ "$RUST_HOST" == "aarch64-apple-darwin" ]] \
  || fail "Rust host must be aarch64-apple-darwin, got $RUST_HOST"

CARGO_TARGET_DIR="$HELPER_ROOT/target" \
  cargo build --locked --release --manifest-path "$MANIFEST" --bin ccbud-gateway
"$ROOT/native/Scripts/verify-gateway-helper.sh" "$BUILD_OUTPUT" arm64

mkdir -p "$VENDOR_DIR"
[[ ! -L "$OUTPUT" ]] || fail "refusing to replace symlink: $OUTPUT"
STAGED="$(mktemp "$VENDOR_DIR/.ccbud-gateway.XXXXXX")"
readonly STAGED
trap 'rm -f -- "$STAGED"' EXIT INT TERM HUP
install -m 0755 "$BUILD_OUTPUT" "$STAGED"
mv -f -- "$STAGED" "$OUTPUT"
"$ROOT/native/Scripts/verify-gateway-helper.sh" "$OUTPUT" arm64

echo "$OUTPUT"
