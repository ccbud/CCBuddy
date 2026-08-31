#!/usr/bin/env bash
set -euo pipefail
umask 077

require_value() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || { echo "missing required secret: $name" >&2; exit 1; }
}

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

unset apple_certificate apple_certificate_password apple_signing_identity
unset keychain_password keychain_path certificate_path certificate_payload
readonly apple_certificate="${APPLE_CERTIFICATE:-}"
readonly apple_certificate_password="${APPLE_CERTIFICATE_PASSWORD:-}"
readonly apple_signing_identity="${APPLE_SIGNING_IDENTITY:-}"
readonly keychain_password="${CCBUD_KEYCHAIN_PASSWORD:-}"
readonly keychain_path="${CCBUD_KEYCHAIN_PATH:-$RUNNER_TEMP/ccbud-signing.keychain-db}"
unset APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY
unset CCBUD_KEYCHAIN_PASSWORD CCBUD_KEYCHAIN_PATH

require_value APPLE_CERTIFICATE "$apple_certificate"
require_value APPLE_CERTIFICATE_PASSWORD "$apple_certificate_password"
require_value APPLE_SIGNING_IDENTITY "$apple_signing_identity"
require_value CCBUD_KEYCHAIN_PASSWORD "$keychain_password"

readonly certificate_path="$RUNNER_TEMP/ccbud-developer-id.p12"
readonly certificate_payload="${apple_certificate#*base64,}"
IMPORT_SUCCEEDED=0

cleanup() {
  rm -f -- "$certificate_path"
  if [[ "$IMPORT_SUCCEEDED" != 1 && -f "$keychain_path" ]]; then
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

[[ "$keychain_path" == "$RUNNER_TEMP"/* && "$keychain_path" != "$RUNNER_TEMP/" ]] \
  || { echo "keychain path must be a child of RUNNER_TEMP" >&2; exit 1; }
[[ ! -e "$keychain_path" ]] || { echo "keychain path already exists" >&2; exit 1; }

printf '%s' "$certificate_payload" | openssl base64 -d -A -out "$certificate_path"
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$certificate_path" -k "$keychain_path" \
  -P "$apple_certificate_password" -T /usr/bin/codesign -T /usr/bin/security \
  -t cert -f pkcs12
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$keychain_password" "$keychain_path" >/dev/null
security list-keychains -d user -s "$keychain_path"

security find-identity -v -p codesigning "$keychain_path" \
  | grep -F "\"$apple_signing_identity\"" >/dev/null \
  || { echo "the requested Developer ID identity was not imported" >&2; exit 1; }

IMPORT_SUCCEEDED=1
echo "$keychain_path"
