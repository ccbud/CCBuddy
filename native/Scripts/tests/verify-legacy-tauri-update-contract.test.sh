#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# The path is anchored to this test, not the caller's working directory.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../verify-legacy-tauri-update-contract.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-legacy-tauri-tests.XXXXXX")"
readonly TEST_ROOT
[[ -d "$TEST_ROOT" && "$TEST_ROOT" == */ccbud-legacy-tauri-tests.* ]] \
  || { echo "failed to create a safe test directory" >&2; exit 1; }
trap 'rm -rf -- "$TEST_ROOT"' EXIT

PASSED=0

test_fail() {
  echo "not ok - $*" >&2
  exit 1
}

pass() {
  PASSED=$((PASSED + 1))
  echo "ok $PASSED - $1"
}

make_archive() {
  local name="$1"
  shift
  local staging="$TEST_ROOT/staging-$name"
  local directory

  mkdir -p "$staging"
  for directory in "$@"; do
    mkdir -p "$staging/$directory"
  done
  /usr/bin/tar -czf "$TEST_ROOT/$name.tar.gz" -C "$staging" "$@"
}

assert_valid() {
  local name="$1"
  local work_root="$TEST_ROOT/work-$name"

  mkdir "$work_root"
  if ! (validate_legacy_tauri_archive_layout "$TEST_ROOT/$name.tar.gz" "$work_root"); then
    test_fail "$name should satisfy the legacy extraction layout"
  fi
  [[ -d "$work_root/tauri_updated_app/Contents" ]] \
    || test_fail "$name did not extract to Contents"
  pass "$name archive layout accepted"
}

assert_invalid() {
  local name="$1"
  local work_root="$TEST_ROOT/work-$name"

  mkdir "$work_root"
  if (validate_legacy_tauri_archive_layout \
    "$TEST_ROOT/$name.tar.gz" "$work_root") >/dev/null 2>&1; then
    test_fail "$name should not satisfy the legacy extraction layout"
  fi
  pass "$name archive layout rejected"
}

make_archive valid 'CC Buddy.app/Contents/MacOS'
make_archive wrong-root 'Wrong.app/Contents'
make_archive two-roots 'CC Buddy.app/Contents' 'Other.app/Contents'
make_archive extra-stripped-root 'CC Buddy.app/Contents' 'CC Buddy.app/Resources'

assert_valid valid
assert_invalid wrong-root
assert_invalid two-roots
assert_invalid extra-stripped-root

echo "verified $PASSED legacy Tauri archive-layout cases"
