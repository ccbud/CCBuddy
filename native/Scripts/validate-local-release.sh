#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
VERSION="$(node "$ROOT/scripts/release-version.js" print)"
readonly VERSION
readonly OUTPUT_DIR="${1:-$ROOT/native/build/unsigned-$VERSION}"
readonly APP_DIR="$OUTPUT_DIR/app"
readonly ARTIFACT_DIR="$OUTPUT_DIR/artifacts"

if [[ -e "$OUTPUT_DIR" ]]; then
  echo "local validation output already exists: $OUTPUT_DIR" >&2
  exit 1
fi

mkdir -p "$APP_DIR" "$ARTIFACT_DIR"
"$ROOT/native/Scripts/build-native-release.sh" unsigned "$VERSION" 1 "$APP_DIR"
"$ROOT/native/Scripts/run-packaged-selfcheck.sh" "$APP_DIR/CC Buddy.app" 150
"$ROOT/native/Scripts/test-single-instance-handoff.sh" "$APP_DIR/CC Buddy.app" 20
"$ROOT/native/Scripts/package-native-release.sh" \
  unsigned "$APP_DIR/CC Buddy.app" "$VERSION" "$ARTIFACT_DIR"

echo "unsigned local release validation passed: $ARTIFACT_DIR"
