#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
readonly HELPER="${1:-$ROOT/native/Vendor/ccbud-gateway}"
readonly REQUESTED_ARCHS="${2:-arm64}"
readonly MANIFEST="$ROOT/native/GatewayHelper/Cargo.toml"
readonly LOCKFILE="$ROOT/native/GatewayHelper/Cargo.lock"
readonly NOTICE="$ROOT/native/GatewayHelper/NOTICE"
readonly BUNDLED_NOTICE="$ROOT/native/Resources/CCBuddyGateway-NOTICE.txt"
readonly THIRD_PARTY_NOTICES="$ROOT/native/GatewayHelper/THIRD-PARTY-NOTICES.txt"
readonly BUNDLED_THIRD_PARTY_NOTICES="$ROOT/native/Resources/CCBuddyGateway-THIRD-PARTY-NOTICES.txt"

fail() { echo "gateway helper verification failed: $*" >&2; exit 1; }

[[ "$REQUESTED_ARCHS" == "arm64" ]] \
  || fail "the native app supports only the arm64 helper architecture"
[[ -f "$MANIFEST" ]] || fail "missing manifest: $MANIFEST"
[[ -f "$LOCKFILE" ]] || fail "missing lockfile: $LOCKFILE"
[[ -s "$NOTICE" ]] || fail "missing gateway attribution notice: $NOTICE"
cmp -s "$NOTICE" "$BUNDLED_NOTICE" \
  || fail "bundled gateway notice is missing or differs from GatewayHelper/NOTICE"
[[ -s "$THIRD_PARTY_NOTICES" ]] \
  || fail "missing gateway third-party notices: $THIRD_PARTY_NOTICES"
cmp -s "$THIRD_PARTY_NOTICES" "$BUNDLED_THIRD_PARTY_NOTICES" \
  || fail "bundled gateway third-party notices are missing or stale"
LOCKFILE_SHA256="$(shasum -a 256 "$LOCKFILE" | awk '{print $1}')"
readonly LOCKFILE_SHA256
grep -Fqx "Cargo.lock SHA-256: $LOCKFILE_SHA256" "$THIRD_PARTY_NOTICES" \
  || fail "gateway third-party notices do not match Cargo.lock"
command -v node >/dev/null || fail "node is required to verify gateway dependency notices"
node "$ROOT/native/Scripts/generate-gateway-third-party-notices.mjs" --check >/dev/null \
  || fail "gateway third-party notices are stale"
[[ -f "$HELPER" && -x "$HELPER" ]] \
  || fail "missing executable helper; run native/Scripts/build-gateway-helper.sh"
command -v lipo >/dev/null || fail "lipo is required"

ACTUAL_ARCHS="$(lipo -archs "$HELPER")"
readonly ACTUAL_ARCHS
[[ "$ACTUAL_ARCHS" == "arm64" ]] || fail "helper architecture is $ACTUAL_ARCHS"

PACKAGE_VERSION=""
IN_PACKAGE=0
while IFS= read -r line; do
  if [[ "$line" == "[package]" ]]; then
    IN_PACKAGE=1
    continue
  fi
  if [[ "$IN_PACKAGE" -eq 1 && "$line" == \[* ]]; then
    break
  fi
  if [[ "$IN_PACKAGE" -eq 1 \
      && "$line" =~ ^version[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
    PACKAGE_VERSION="${BASH_REMATCH[1]}"
    break
  fi
done < "$MANIFEST"
readonly PACKAGE_VERSION
[[ -n "$PACKAGE_VERSION" ]] || fail "could not read the package version"

IDENTITY="$("$HELPER" --version)"
readonly IDENTITY
[[ "$IDENTITY" == "ccbud-gateway $PACKAGE_VERSION" ]] \
  || fail "unexpected helper identity: $IDENTITY"

echo "verified arm64 ccbud-gateway $PACKAGE_VERSION: $HELPER"
