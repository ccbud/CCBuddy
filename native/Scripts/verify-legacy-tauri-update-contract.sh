#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT

fail() { echo "legacy Tauri updater contract verification failed: $*" >&2; exit 1; }

# tauri-plugin-updater 2.10.1's macOS installer strips the first component from every
# tar entry, then renames that extraction directory onto the running .app path. Exercise
# that archive contract directly without claiming to launch or drive the legacy app.
validate_legacy_tauri_archive_layout() {
  local archive="${1:-}"
  local work_root="${2:-}"
  local archive_roots
  local tauri_extracted
  local top_level

  [[ -f "$archive" ]] || fail "updater archive is missing: $archive"
  [[ -d "$work_root" ]] || fail "archive validation work directory is missing: $work_root"
  archive_roots="$(/usr/bin/tar -tzf "$archive" \
    | sed 's#^\./##' | awk -F/ 'NF {print $1}' | LC_ALL=C sort -u)"
  [[ "$archive_roots" == 'CC Buddy.app' ]] \
    || fail "archive must have the single CC Buddy.app root"
  if /usr/bin/tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    fail "archive contains a path that the legacy updater must not install"
  fi

  tauri_extracted="$work_root/tauri_updated_app"
  mkdir "$tauri_extracted"
  /usr/bin/tar -xzf "$archive" --strip-components 1 -C "$tauri_extracted"
  top_level="$(find "$tauri_extracted" -mindepth 1 -maxdepth 1 -print \
    | sed 's#^.*/##' | LC_ALL=C sort)"
  [[ "$top_level" == Contents ]] \
    || fail "stripped archive must become one Contents directory"
}

main() {
  local archive="${1:-}"
  local signature="${2:-}"
  local manifest="${3:-}"
  local version="${4:-}"
  local repository="${5:-ccbud/ccbud}"
  local executable_name

  [[ "$(uname -s)" == Darwin ]] || fail "macOS is required"
  [[ -f "$archive" ]] || fail "updater archive is missing: $archive"
  [[ -f "$signature" ]] || fail "updater signature is missing: $signature"
  [[ -f "$manifest" ]] || fail "updater manifest is missing: $manifest"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be x.y.z"
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "invalid repository"

  node "$ROOT/native/Scripts/verify-legacy-tauri-manifest.js" \
    --version "$version" --repository "$repository" \
    --artifact "$archive" --signature "$signature" --manifest "$manifest" \
    --config "$ROOT/src-tauri/tauri.conf.json"

  WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-legacy-tauri-contract.XXXXXX")"
  readonly WORK_ROOT
  trap 'rm -rf -- "$WORK_ROOT"' EXIT
  validate_legacy_tauri_archive_layout "$archive" "$WORK_ROOT"

  readonly TAURI_EXTRACTED="$WORK_ROOT/tauri_updated_app"
  readonly REPLACEMENT_APP="$WORK_ROOT/CC Buddy.app"
  mv "$TAURI_EXTRACTED" "$REPLACEMENT_APP"
  [[ -f "$REPLACEMENT_APP/Contents/Info.plist" ]] || fail "replacement Info.plist is missing"
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$REPLACEMENT_APP/Contents/Info.plist")"
  readonly executable_name
  [[ -n "$executable_name" ]] || fail "replacement CFBundleExecutable is empty"
  [[ -x "$REPLACEMENT_APP/Contents/MacOS/$executable_name" ]] \
    || fail "replacement executable does not match CFBundleExecutable"

  "$ROOT/native/Scripts/verify-release-app.sh" "$REPLACEMENT_APP" "$version" stapled
  echo "verified signed native archive at the legacy Tauri 1.3.9 install boundary"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
