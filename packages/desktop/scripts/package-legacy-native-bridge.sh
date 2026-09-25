#!/usr/bin/env bash
# 修复原因：2.0.3–2.0.9 原生版只安装 bundle id 为 dev.ccbud.gateway、Team 2CGR266XD2、
# 已 staple 公证票据、并带 Tauri minisign 签名的 .app.tar.gz；Electron 正式包
# （app.ccbuddy.desktop）不满足这些条件，旧客户端无法热更。这里把已签名的正式包复制成
# 旧身份的桥接包，并把指定要求（designated requirement）放宽到只校验 Team，
# 让桥接包之后能通过 Squirrel 接受正常的 app.ccbuddy.desktop 更新。
# 契约与验收见 docs/specs/legacy-native-update-bridge.md。
set -euo pipefail

readonly SOURCE_APP="${1:-}"
readonly VERSION="${2:-}"
[[ -d "${3:-}" ]] || { echo "legacy native bridge packaging failed: dist directory is missing: ${3:-}" >&2; exit 1; }
# 签名步骤会切换工作目录，统一使用绝对路径。
DIST_DIR="$(cd "$3" && pwd)"
readonly DIST_DIR
readonly REPOSITORY="${4:-}"
readonly LEGACY_BUNDLE_ID="dev.ccbud.gateway"
readonly LEGACY_TEAM_ID="2CGR266XD2"
readonly TAURI_CLI_VERSION="2.11.3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

fail() { echo "legacy native bridge packaging failed: $*" >&2; exit 1; }

# 只在需要的命令上显式传递凭据，不让 npx 下载的签名工具看到 Apple 凭据。
readonly signing_identity="${APPLE_SIGNING_IDENTITY:-}"
readonly signing_keychain="${CSC_KEYCHAIN:-}"
readonly team_id="${APPLE_TEAM_ID:-}"
readonly notary_key_path="${APPLE_API_KEY_PATH:-}"
readonly notary_key_id="${APPLE_API_KEY_ID:-}"
readonly notary_issuer="${APPLE_API_ISSUER:-}"
readonly updater_key="${TAURI_SIGNING_PRIVATE_KEY:-}"
# 未加密的 Tauri 私钥密码合法为空。
readonly updater_password="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
unset APPLE_SIGNING_IDENTITY APPLE_TEAM_ID APPLE_API_KEY_PATH APPLE_API_KEY_ID APPLE_API_ISSUER
unset TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD

[[ "$(uname -s)" == Darwin ]] || fail "macOS is required"
[[ -d "$SOURCE_APP" ]] || fail "signed app is missing: $SOURCE_APP"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid version: $VERSION"
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "invalid repository"
for name in signing_identity signing_keychain notary_key_path notary_key_id notary_issuer updater_key; do
  [[ -n "${!name}" ]] || fail "missing required input: $name"
done
[[ -f "$notary_key_path" ]] || fail "notary API key is not a file"
# 旧客户端硬编码了 Team ID；换了 Team 的签名无论如何都装不上，发布前直接失败。
[[ "$team_id" == "$LEGACY_TEAM_ID" ]] \
  || fail "APPLE_TEAM_ID must be $LEGACY_TEAM_ID for the legacy native updater"

readonly ARCHIVE_NAME="CCbuddy-${VERSION}-legacy-mac-arm64.app.tar.gz"
readonly ARCHIVE="$DIST_DIR/$ARCHIVE_NAME"
for output in "$ARCHIVE" "$ARCHIVE.sig" "$DIST_DIR/latest.json"; do
  [[ ! -e "$output" ]] || fail "output already exists: $output"
done

WORK_ROOT="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ccbuddy-legacy-bridge.XXXXXX")"
readonly WORK_ROOT
trap 'rm -rf -- "$WORK_ROOT"' EXIT
readonly APP="$WORK_ROOT/CCbuddy.app"

readonly TEAM_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$LEGACY_TEAM_ID\""
# 与 v2.0.5 DeveloperIDUpdateVerifier 使用的发布者要求逐字一致。
readonly LEGACY_CLIENT_REQUIREMENT="$TEAM_REQUIREMENT and identifier \"$LEGACY_BUNDLE_ID\""

verify_bridge_app() {
  local app="$1"
  local info="$app/Contents/Info.plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" == "$LEGACY_BUNDLE_ID" ]] \
    || fail "bridge bundle id mismatch in $app"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" == "$VERSION" ]] \
    || fail "bridge version mismatch in $app"
  codesign --verify --deep --strict --verbose=2 "$app"
  codesign --verify --strict --test-requirement="=$LEGACY_CLIENT_REQUIREMENT" "$app" \
    || fail "bridge does not satisfy the legacy client code requirement"
  node "$SCRIPT_DIR/legacy-native-update.mjs" check-symlinks "$app"
}

ditto "$SOURCE_APP" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $LEGACY_BUNDLE_ID" "$APP/Contents/Info.plist"
# 只重签外层 bundle：内层 Helper、框架和预签名工具保持原签名；
# 外层签名重新封存修改后的 Info.plist，并写入只校验 Team 的指定要求。
codesign --force --timestamp --options runtime --preserve-metadata=entitlements \
  --identifier "$LEGACY_BUNDLE_ID" \
  --requirements "=designated => $TEAM_REQUIREMENT" \
  --sign "$signing_identity" --keychain "$signing_keychain" "$APP"
codesign -dvv "$APP" 2>&1 | grep -Fx "TeamIdentifier=$LEGACY_TEAM_ID" >/dev/null \
  || fail "bridge Team ID mismatch"
verify_bridge_app "$APP"

# Squirrel.Mac 用运行中应用的指定要求校验更新包：确认桥接包的指定要求不绑定 identifier，
# 且正式包满足它，桥接包的第一次 Electron 更新才能成功。
bridge_requirement="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
[[ -n "$bridge_requirement" ]] || fail "bridge has no designated requirement"
[[ "$bridge_requirement" != *identifier* ]] \
  || fail "bridge designated requirement must not pin an identifier: $bridge_requirement"
codesign --verify --strict --test-requirement="=$bridge_requirement" "$SOURCE_APP" \
  || fail "the normal app does not satisfy the bridge's designated requirement"

readonly NOTARY_ZIP="$WORK_ROOT/CCbuddy-legacy-bridge.zip"
readonly NOTARY_RESULT="$WORK_ROOT/notary.json"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --key "$notary_key_path" --key-id "$notary_key_id" \
  --issuer "$notary_issuer" --wait --timeout 30m --output-format json | tee "$NOTARY_RESULT"
[[ "$(/usr/bin/plutil -extract status raw -o - "$NOTARY_RESULT")" == Accepted ]] \
  || fail "bridge notarization was not accepted"
# 旧客户端要求应用内随附公证票据。
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"
verify_bridge_app "$APP"

# COPYFILE_DISABLE 避免 bsdtar 在顶层写入 ._ AppleDouble 条目，旧客户端要求单一 .app 根。
COPYFILE_DISABLE=1 /usr/bin/tar -czf "$ARCHIVE" -C "$WORK_ROOT" CCbuddy.app
archive_roots="$(/usr/bin/tar -tzf "$ARCHIVE" | sed 's#^\./##' | awk -F/ 'NF {print $1}' | LC_ALL=C sort -u)"
[[ "$archive_roots" == CCbuddy.app ]] || fail "archive must have the single CCbuddy.app root"
if /usr/bin/tar -tzf "$ARCHIVE" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  fail "archive contains a path the legacy updater rejects"
fi
readonly EXTRACTED="$WORK_ROOT/extracted"
mkdir "$EXTRACTED"
/usr/bin/tar -xzf "$ARCHIVE" -C "$EXTRACTED"
verify_bridge_app "$EXTRACTED/CCbuddy.app"
xcrun stapler validate "$EXTRACTED/CCbuddy.app"

(
  cd "$WORK_ROOT"
  TAURI_SIGNING_PRIVATE_KEY="$updater_key" \
  TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$updater_password" \
    npx --yes "@tauri-apps/cli@$TAURI_CLI_VERSION" signer sign "$ARCHIVE"
)
[[ -s "$ARCHIVE.sig" ]] || fail "Tauri signer did not create $ARCHIVE.sig"
# 生成 latest.json 前用旧客户端内置公钥重新验签，签错钥匙会在这里失败。
node "$SCRIPT_DIR/legacy-native-update.mjs" write "$DIST_DIR" "$VERSION" "$REPOSITORY"
echo "packaged legacy native bridge $ARCHIVE_NAME"
