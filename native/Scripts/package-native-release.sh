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
# An unencrypted Tauri private key legitimately has no password.
readonly updater_signing_password="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
unset APPLE_API_KEY_PATH APPLE_API_KEY_ID APPLE_API_ISSUER APPLE_SIGNING_IDENTITY
unset TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD

fail() { echo "native release packaging failed: $*" >&2; exit 1; }
require_value() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || fail "missing required secret: $name"
}
notarize_and_staple() {
  local submission="$1"
  local staple_target="$2"
  local label="$3"
  local result="$WORK_ROOT/notary-$label.json"
  local submit_exit submission_id submission_status

  set +e
  xcrun notarytool submit "$submission" --key "$apple_api_key_path" \
    --key-id "$apple_api_key_id" --issuer "$apple_api_issuer" \
    --wait --timeout 30m --output-format json | tee "$result"
  submit_exit="${PIPESTATUS[0]}"
  set -e

  submission_id="$(/usr/bin/plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  submission_status="$(/usr/bin/plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  if [[ "$submit_exit" -ne 0 || "$submission_status" != Accepted ]]; then
    if [[ "$submission_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
      xcrun notarytool log "$submission_id" --key "$apple_api_key_path" \
        --key-id "$apple_api_key_id" --issuer "$apple_api_issuer" || true
    fi
    fail "$label notarization failed (status: ${submission_status:-unknown})"
  fi

  xcrun stapler staple "$staple_target"
  xcrun stapler validate "$staple_target"
}

case "$MODE" in signed|unsigned) ;; *) fail "usage: $0 <signed|unsigned> <app> <version> <output-dir> [owner/repo]" ;; esac
[[ -d "$APP_SOURCE" ]] || fail "app is missing: $APP_SOURCE"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid version"
[[ -n "$OUTPUT_DIR" && "$OUTPUT_DIR" != "/" ]] || fail "unsafe output directory"
# Named for what the archive holds. A universal build published as `_aarch64` would tell every
# Intel Mac owner, on the release page and in the cask, that there is nothing here for them.
if [[ "$MODE" == "signed" ]]; then
  readonly UPDATER="$OUTPUT_DIR/CC.Buddy_universal.app.tar.gz"
  readonly DMG="$OUTPUT_DIR/CC.Buddy_${VERSION}_universal.dmg"
  readonly EXTRA_OUTPUTS=("$UPDATER.sig" "$OUTPUT_DIR/latest.json")
else
  readonly UPDATER="$OUTPUT_DIR/CC.Buddy_universal.unsigned.app.tar.gz"
  readonly DMG="$OUTPUT_DIR/CC.Buddy_${VERSION}_universal.unsigned.dmg"
  readonly EXTRA_OUTPUTS=("$OUTPUT_DIR/UNSIGNED-NOT-FOR-DISTRIBUTION.txt")
fi
for output in "$UPDATER" "$DMG" "${EXTRA_OUTPUTS[@]}"; do
  [[ ! -e "$output" ]] || fail "output already exists: $output"
done
mkdir -p "$OUTPUT_DIR"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-package.XXXXXX")"
readonly WORK_ROOT
DMG_MOUNTPOINT=""
cleanup() {
  local status=$?
  set +e
  if [[ -n "$DMG_MOUNTPOINT" ]]; then
    if ! hdiutil detach "$DMG_MOUNTPOINT" >/dev/null 2>&1; then
      if ! hdiutil detach -force "$DMG_MOUNTPOINT" >/dev/null 2>&1; then
        echo "native release packaging cleanup failed: could not detach $DMG_MOUNTPOINT; preserved $WORK_ROOT" >&2
        [[ "$status" -ne 0 ]] || status=1
        exit "$status"
      fi
    fi
  fi
  rm -rf -- "$WORK_ROOT"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
readonly APP="$WORK_ROOT/CC Buddy.app"
ditto "$APP_SOURCE" "$APP"

if [[ "$MODE" == "signed" ]]; then
  require_value APPLE_API_KEY_PATH "$apple_api_key_path"
  require_value APPLE_API_KEY_ID "$apple_api_key_id"
  require_value APPLE_API_ISSUER "$apple_api_issuer"
  require_value APPLE_SIGNING_IDENTITY "$apple_signing_identity"
  require_value TAURI_SIGNING_PRIVATE_KEY "$updater_signing_key"
  [[ -f "$apple_api_key_path" ]] || fail "APPLE_API_KEY_PATH is not a file"
  "$ROOT/native/Scripts/verify-release-app.sh" "$APP" "$VERSION" signed

  readonly NOTARY_ZIP="$WORK_ROOT/CC.Buddy.notary.zip"
  ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
  notarize_and_staple "$NOTARY_ZIP" "$APP" app
  "$ROOT/native/Scripts/verify-release-app.sh" "$APP" "$VERSION" stapled
  "$ROOT/native/Scripts/run-packaged-selfcheck.sh" "$APP" 150 developer-id
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
if [[ "$MODE" == "signed" ]]; then
  "$ROOT/native/Scripts/run-packaged-selfcheck.sh" \
    "$EXTRACTED/CC Buddy.app" 150 developer-id
fi

readonly DMG_ROOT="$WORK_ROOT/dmg-root"
mkdir "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/CC Buddy.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname 'CC Buddy' -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"

if [[ "$MODE" == "signed" ]]; then
  codesign --force --timestamp --sign "$apple_signing_identity" "$DMG"
  codesign --verify --verbose=2 "$DMG"
  notarize_and_staple "$DMG" "$DMG" dmg
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

  DMG_MOUNTPOINT="$WORK_ROOT/mounted-dmg"
  mkdir "$DMG_MOUNTPOINT"
  hdiutil attach -readonly -nobrowse -noautoopen \
    -mountpoint "$DMG_MOUNTPOINT" "$DMG"
  readonly MOUNTED_APP="$DMG_MOUNTPOINT/CC Buddy.app"
  "$ROOT/native/Scripts/verify-release-app.sh" "$MOUNTED_APP" "$VERSION" stapled
  "$ROOT/native/Scripts/run-packaged-selfcheck.sh" \
    "$MOUNTED_APP" 150 developer-id
  hdiutil detach "$DMG_MOUNTPOINT"
  DMG_MOUNTPOINT=""

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
