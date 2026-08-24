#!/usr/bin/env bash
set -euo pipefail

readonly MODE="${1:-}"
readonly APP_SOURCE="${2:-}"
readonly VERSION="${3:-}"
readonly OUTPUT_DIR="${4:-}"
readonly REPOSITORY="${5:-ccbud/ccbud}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
readonly TAG="v$VERSION"
unset apple_api_key_path apple_api_key_id apple_api_issuer apple_signing_identity
unset updater_signing_key updater_signing_password
readonly apple_api_key_path="${APPLE_API_KEY_PATH:-}"
readonly apple_api_key_id="${APPLE_API_KEY_ID:-}"
readonly apple_api_issuer="${APPLE_API_ISSUER:-}"
readonly apple_signing_identity="${APPLE_SIGNING_IDENTITY:-}"
readonly updater_signing_key="${TAURI_SIGNING_PRIVATE_KEY:-}"
readonly updater_signing_password="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
unset APPLE_API_KEY_PATH APPLE_API_KEY_ID APPLE_API_ISSUER APPLE_SIGNING_IDENTITY
unset TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD

fail() { echo "native release packaging failed: $*" >&2; exit 1; }
require_value() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || fail "missing required secret: $name"
}

case "$MODE" in signed|unsigned) ;; *) fail "usage: $0 <signed|unsigned> <app> <version> <output-dir> [owner/repo]" ;; esac
[[ -d "$APP_SOURCE" ]] || fail "app is missing: $APP_SOURCE"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid version"
[[ -n "$OUTPUT_DIR" && "$OUTPUT_DIR" != "/" ]] || fail "unsafe output directory"
if [[ "$MODE" == "signed" ]]; then
  readonly UPDATER="$OUTPUT_DIR/CC.Buddy_aarch64.app.tar.gz"
  readonly DMG="$OUTPUT_DIR/CC.Buddy_${VERSION}_aarch64.dmg"
  readonly EXTRA_OUTPUTS=("$UPDATER.sig" "$OUTPUT_DIR/latest.json")
else
  readonly UPDATER="$OUTPUT_DIR/CC.Buddy_aarch64.unsigned.app.tar.gz"
  readonly DMG="$OUTPUT_DIR/CC.Buddy_${VERSION}_aarch64.unsigned.dmg"
  readonly EXTRA_OUTPUTS=("$OUTPUT_DIR/UNSIGNED-NOT-FOR-DISTRIBUTION.txt")
fi
for output in "$UPDATER" "$DMG" "${EXTRA_OUTPUTS[@]}"; do
  [[ ! -e "$output" ]] || fail "output already exists: $output"
done
mkdir -p "$OUTPUT_DIR"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-package.XXXXXX")"
readonly WORK_ROOT
trap 'rm -rf "$WORK_ROOT"' EXIT
readonly APP="$WORK_ROOT/CC Buddy.app"
SOURCE_VERIFY_MODE="$([[ "$MODE" == "signed" ]] && echo signed || echo unsigned)"
readonly SOURCE_VERIFY_MODE
"$ROOT/native/Scripts/verify-release-app.sh" \
  "$APP_SOURCE" "$VERSION" "$SOURCE_VERIFY_MODE"
ditto "$APP_SOURCE" "$APP"

if [[ "$MODE" == "signed" ]]; then
  require_value APPLE_API_KEY_PATH "$apple_api_key_path"
  require_value APPLE_API_KEY_ID "$apple_api_key_id"
  require_value APPLE_API_ISSUER "$apple_api_issuer"
  require_value APPLE_SIGNING_IDENTITY "$apple_signing_identity"
  require_value TAURI_SIGNING_PRIVATE_KEY "$updater_signing_key"
  require_value TAURI_SIGNING_PRIVATE_KEY_PASSWORD "$updater_signing_password"
  [[ -f "$apple_api_key_path" ]] || fail "APPLE_API_KEY_PATH is not a file"
  readonly NOTARY_ZIP="$WORK_ROOT/CC.Buddy.notary.zip"
  ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" --key "$apple_api_key_path" \
    --key-id "$apple_api_key_id" --issuer "$apple_api_issuer" \
    --wait --timeout 30m
  xcrun stapler staple "$APP"
  "$ROOT/native/Scripts/verify-release-app.sh" "$APP" "$VERSION" stapled
fi

/usr/bin/tar -czf "$UPDATER" -C "$WORK_ROOT" 'CC Buddy.app'
ARCHIVE_ROOTS="$(/usr/bin/tar -tzf "$UPDATER" | sed 's#^\./##' | awk -F/ 'NF {print $1}' | sort -u)"
readonly ARCHIVE_ROOTS
[[ "$ARCHIVE_ROOTS" == 'CC Buddy.app' ]] || fail "updater archive must have one app root"
if /usr/bin/tar -tzf "$UPDATER" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  fail "updater archive contains an unsafe path"
fi
readonly EXTRACTED="$WORK_ROOT/extracted"
mkdir "$EXTRACTED"
/usr/bin/tar -xzf "$UPDATER" -C "$EXTRACTED"
VERIFY_MODE="$([[ "$MODE" == "signed" ]] && echo stapled || echo unsigned)"
readonly VERIFY_MODE
"$ROOT/native/Scripts/verify-release-app.sh" "$EXTRACTED/CC Buddy.app" "$VERSION" "$VERIFY_MODE"

readonly DMG_ROOT="$WORK_ROOT/dmg-root"
mkdir "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/CC Buddy.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname 'CC Buddy' -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"

if [[ "$MODE" == "signed" ]]; then
  codesign --force --timestamp --sign "$apple_signing_identity" "$DMG"
  codesign --verify --verbose=2 "$DMG"
  xcrun notarytool submit "$DMG" --key "$apple_api_key_path" \
    --key-id "$apple_api_key_id" --issuer "$apple_api_issuer" \
    --wait --timeout 30m
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

  (
    cd "$ROOT"
    TAURI_SIGNING_PRIVATE_KEY="$updater_signing_key" \
    TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$updater_signing_password" \
      npx --no-install tauri signer sign "$UPDATER"
  )
  [[ -s "$UPDATER.sig" ]] || fail "Tauri signer did not create $UPDATER.sig"
  node "$ROOT/native/Scripts/generate-latest-json.js" \
    --version "$VERSION" --repository "$REPOSITORY" --tag "$TAG" \
    --artifact "$UPDATER" --signature "$UPDATER.sig" \
    --output "$OUTPUT_DIR/latest.json"
else
  printf '%s\n' 'UNSIGNED LOCAL VALIDATION ARTIFACTS — DO NOT DISTRIBUTE' \
    > "$OUTPUT_DIR/UNSIGNED-NOT-FOR-DISTRIBUTION.txt"
fi

shasum -a 256 "$UPDATER" "$DMG"
echo "packaged $MODE artifacts in $OUTPUT_DIR"
