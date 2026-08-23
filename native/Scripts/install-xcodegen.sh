#!/usr/bin/env bash
set -euo pipefail

readonly XCODEGEN_VERSION="2.46.0"
readonly XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
readonly XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
readonly INSTALL_ROOT="${1:-}"

fail() { echo "XcodeGen installation failed: $*" >&2; exit 1; }

[[ -n "$INSTALL_ROOT" && "$INSTALL_ROOT" != "/" ]] \
  || fail "usage: $0 <empty-install-directory>"
[[ ! -e "$INSTALL_ROOT" ]] || fail "install path already exists: $INSTALL_ROOT"
command -v curl >/dev/null || fail "curl is required"
command -v shasum >/dev/null || fail "shasum is required"
command -v unzip >/dev/null || fail "unzip is required"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-xcodegen.XXXXXX")"
readonly TEMP_ROOT
readonly ARCHIVE="$TEMP_ROOT/xcodegen.zip"
cleanup() { rm -rf -- "$TEMP_ROOT"; }
trap cleanup EXIT INT TERM

curl --fail --location --retry 3 --silent --show-error \
  --output "$ARCHIVE" "$XCODEGEN_URL"
ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
readonly ACTUAL_SHA256
[[ "$ACTUAL_SHA256" == "$XCODEGEN_SHA256" ]] \
  || fail "archive checksum mismatch: $ACTUAL_SHA256"

mkdir -p "$INSTALL_ROOT"
unzip -q "$ARCHIVE" -d "$INSTALL_ROOT"
readonly XCODEGEN_BIN="$INSTALL_ROOT/xcodegen/bin/xcodegen"
[[ -x "$XCODEGEN_BIN" ]] || fail "archive did not contain the xcodegen executable"
[[ "$($XCODEGEN_BIN --version)" == "Version: $XCODEGEN_VERSION" ]] \
  || fail "installed executable did not report version $XCODEGEN_VERSION"

echo "$XCODEGEN_BIN"
