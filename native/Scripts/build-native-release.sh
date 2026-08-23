#!/usr/bin/env bash
set -euo pipefail

readonly MODE="${1:-}"
readonly VERSION="${2:-}"
readonly BUILD_NUMBER="${3:-}"
readonly OUTPUT_DIR="${4:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
readonly PROJECT="$ROOT/native/CCBuddy.xcodeproj"
readonly SCHEME="CCBuddy"
readonly TEAM_ID="2CGR266XD2"
unset apple_team_id apple_signing_identity signing_keychain signing_flags
readonly apple_team_id="${APPLE_TEAM_ID:-}"
readonly apple_signing_identity="${APPLE_SIGNING_IDENTITY:-}"
readonly signing_keychain="${CCBUD_KEYCHAIN:-}"
unset APPLE_TEAM_ID APPLE_SIGNING_IDENTITY CCBUD_KEYCHAIN

fail() { echo "native release build failed: $*" >&2; exit 1; }
require_value() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || fail "missing required value: $name"
}

case "$MODE" in signed|unsigned) ;; *) fail "usage: $0 <signed|unsigned> <version> <build-number> <output-dir>" ;; esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid version: $VERSION"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "build number must be a positive integer"
[[ -n "$OUTPUT_DIR" && "$OUTPUT_DIR" != "/" ]] || fail "unsafe output directory"
command -v xcodegen >/dev/null || fail "xcodegen is required"
[[ "$(xcodegen --version)" == "Version: 2.46.0" ]] \
  || fail "XcodeGen 2.46.0 is required"

if [[ ! -x "$ROOT/native/Vendor/bifrost-http" ]]; then
  [[ "$MODE" == "unsigned" ]] \
    || fail "signed builds require the pinned Bifrost helper to be prepared before credentials"
  CCBUD_BIFROST_ARCH=arm64 "$ROOT/native/Scripts/fetch-bifrost.sh" >/dev/null
fi
"$ROOT/native/Scripts/verify-bifrost.sh" "$ROOT/native/Vendor/bifrost-http" arm64

xcodegen generate --spec "$ROOT/native/project.yml" --project "$ROOT/native"
node "$ROOT/scripts/release-version.js" check "$VERSION"

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-native-build.XXXXXX")"
readonly BUILD_ROOT
trap 'rm -rf "$BUILD_ROOT"' EXIT
mkdir -p "$OUTPUT_DIR"
[[ ! -e "$OUTPUT_DIR/CC Buddy.app" ]] || fail "output app already exists"

if [[ "$MODE" == "signed" ]]; then
  require_value APPLE_TEAM_ID "$apple_team_id"
  require_value APPLE_SIGNING_IDENTITY "$apple_signing_identity"
  require_value CCBUD_KEYCHAIN "$signing_keychain"
  [[ -f "$signing_keychain" ]] || fail "CCBUD_KEYCHAIN must be an existing keychain"
  [[ "$apple_team_id" == "$TEAM_ID" ]] || fail "APPLE_TEAM_ID must be $TEAM_ID"
  [[ "$apple_signing_identity" == Developer\ ID\ Application:* ]] \
    || fail "APPLE_SIGNING_IDENTITY must be a Developer ID Application identity"

  readonly ARCHIVE_PATH="$BUILD_ROOT/CCBuddy.xcarchive"
  readonly EXPORT_PATH="$BUILD_ROOT/export"
  readonly signing_flags="--keychain $signing_keychain"
  xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE_PATH" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$apple_signing_identity" \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="$signing_flags"
  xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$ROOT/native/Support/ExportOptions.plist"
  [[ -d "$EXPORT_PATH/CC Buddy.app" ]] || fail "export did not produce CC Buddy.app"
  ditto "$EXPORT_PATH/CC Buddy.app" "$OUTPUT_DIR/CC Buddy.app"
else
  readonly PRODUCTS_PATH="$BUILD_ROOT/products"
  xcodebuild build \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=YES \
    CONFIGURATION_BUILD_DIR="$PRODUCTS_PATH"
  [[ -d "$PRODUCTS_PATH/CC Buddy.app" ]] || fail "build did not produce CC Buddy.app"
  ditto "$PRODUCTS_PATH/CC Buddy.app" "$OUTPUT_DIR/CC Buddy.app"
fi

"$ROOT/native/Scripts/verify-release-app.sh" \
  "$OUTPUT_DIR/CC Buddy.app" "$VERSION" "$MODE" "$BUILD_NUMBER"
echo "$OUTPUT_DIR/CC Buddy.app"
