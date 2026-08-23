#!/usr/bin/env bash
set -euo pipefail

readonly APP_PATH="${1:-}"
readonly EXPECTED_VERSION="${2:-}"
readonly MODE="${3:-unsigned}"
readonly EXPECTED_BUILD="${4:-}"
readonly EXPECTED_BUNDLE_ID="dev.ccbud.gateway"
readonly EXPECTED_TEAM_ID="2CGR266XD2"
readonly EXPECTED_MINIMUM_SYSTEM_VERSION="13.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT

fail() { echo "release app verification failed: $*" >&2; exit 1; }

[[ -d "$APP_PATH" ]] || fail "missing app: $APP_PATH"
[[ "$(basename "$APP_PATH")" == "CC Buddy.app" ]] || fail "wrapper must be CC Buddy.app"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid version"
case "$MODE" in unsigned|signed|stapled) ;; *) fail "mode must be unsigned, signed, or stapled" ;; esac

readonly INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist is missing"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
readonly BUNDLE_ID VERSION BUILD_VERSION MINIMUM_SYSTEM_VERSION EXECUTABLE_NAME
readonly EXECUTABLE="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
readonly HELPER="$APP_PATH/Contents/MacOS/bifrost-http"

[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "bundle id is $BUNDLE_ID"
[[ "$VERSION" == "$EXPECTED_VERSION" ]] || fail "version is $VERSION, expected $EXPECTED_VERSION"
[[ "$BUILD_VERSION" =~ ^[1-9][0-9]*$ ]] || fail "build version is not a positive integer"
if [[ -n "$EXPECTED_BUILD" ]]; then
  [[ "$EXPECTED_BUILD" =~ ^[1-9][0-9]*$ ]] || fail "expected build version is invalid"
  [[ "$BUILD_VERSION" == "$EXPECTED_BUILD" ]] \
    || fail "build version is $BUILD_VERSION, expected $EXPECTED_BUILD"
fi
[[ "$MINIMUM_SYSTEM_VERSION" == "$EXPECTED_MINIMUM_SYSTEM_VERSION" ]] \
  || fail "minimum system version is $MINIMUM_SYSTEM_VERSION"
[[ -x "$EXECUTABLE" ]] || fail "main executable is missing"
[[ -x "$HELPER" ]] || fail "bifrost-http is missing"
[[ "$(lipo -archs "$EXECUTABLE")" == "arm64" ]] || fail "main executable is not arm64-only"
[[ "$(lipo -archs "$HELPER")" == "arm64" ]] || fail "bifrost-http is not arm64-only"
cmp -s "$APP_PATH/Contents/Resources/LICENSE" "$ROOT/LICENSE" \
  || fail "GPL-3.0 license resource is missing or changed"
cmp -s "$APP_PATH/Contents/Resources/Bifrost-LICENSE.txt" \
  "$ROOT/native/Resources/Bifrost-LICENSE.txt" \
  || fail "Bifrost Apache-2.0 license resource is missing or changed"

if [[ "$MODE" != "unsigned" ]]; then
  command -v jq >/dev/null || fail "jq is required to compare signed entitlements"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  codesign --verify --strict --verbose=2 "$HELPER"

  APP_SIGNATURE="$(codesign -dvvv "$APP_PATH" 2>&1)"
  HELPER_SIGNATURE="$(codesign -dvvv "$HELPER" 2>&1)"
  readonly APP_SIGNATURE HELPER_SIGNATURE
  grep -Fq "Authority=Developer ID Application:" <<<"$APP_SIGNATURE" || fail "app is not Developer ID signed"
  grep -Fq "Identifier=$EXPECTED_BUNDLE_ID" <<<"$APP_SIGNATURE" || fail "app signature identifier mismatch"
  grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$APP_SIGNATURE" || fail "app Team ID mismatch"
  grep -Fq 'Timestamp=' <<<"$APP_SIGNATURE" || fail "app signature has no secure timestamp"
  grep -Eq 'flags=.*runtime' <<<"$APP_SIGNATURE" || fail "hardened runtime is disabled"
  grep -Fq "Authority=Developer ID Application:" <<<"$HELPER_SIGNATURE" || fail "helper is not Developer ID signed"
  grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$HELPER_SIGNATURE" || fail "helper Team ID mismatch"
  grep -Fq 'Timestamp=' <<<"$HELPER_SIGNATURE" || fail "helper signature has no secure timestamp"
  grep -Eq 'flags=.*runtime' <<<"$HELPER_SIGNATURE" || fail "helper hardened runtime is disabled"

  ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/ccbud-entitlements.XXXXXX")"
  readonly ENTITLEMENTS
  trap 'rm -f -- "$ENTITLEMENTS"' EXIT
  codesign -d --entitlements - --xml "$APP_PATH" > "$ENTITLEMENTS"
  EXPECTED_ENTITLEMENTS="$(plutil -convert json -o - \
    "$ROOT/native/Support/CCBuddy.entitlements" | jq -S -c .)"
  ACTUAL_ENTITLEMENTS="$(plutil -convert json -o - "$ENTITLEMENTS" | jq -S -c .)"
  readonly EXPECTED_ENTITLEMENTS ACTUAL_ENTITLEMENTS
  [[ "$ACTUAL_ENTITLEMENTS" == "$EXPECTED_ENTITLEMENTS" ]] \
    || fail "signed entitlements differ from CCBuddy.entitlements"
fi

if [[ "$MODE" == "stapled" ]]; then
  xcrun stapler validate "$APP_PATH"
  spctl --assess --type execute --verbose=4 "$APP_PATH"
fi

echo "verified $MODE arm64 app: $APP_PATH"
