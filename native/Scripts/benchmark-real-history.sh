#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly ROOT
readonly LIBRARY="$ROOT/native/Vendor/libccbuddy_tgrep.dylib"
[[ -f "$LIBRARY" ]] || { echo 'First run bash native/Scripts/build-tgrep.sh' >&2; exit 1; }
# This temporary directory holds only the compiler bundle and isolated empty import scope.
# Persistent file catalogs require the caller's explicit --catalog private benchmark directory;
# neither this launcher nor the executable copies or opens the daily app catalog for writing.
mkdir -p "$ROOT/native/build"
work="$(mktemp -d "$ROOT/native/build/ccbuddy-history-benchmark.XXXXXX")"
readonly work
trap 'rm -rf -- "$work"' EXIT
readonly bundle="$work/HistoryBenchmark.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks"
cp "$ROOT/native/Scripts/HistoryBenchmarkInfo.plist" "$bundle/Contents/Info.plist"
cp "$LIBRARY" "$bundle/Contents/Frameworks/"
sources=()
while IFS= read -r file; do
  case "$(basename "$file")" in
    HistoryDirectoryDiscovery.swift) continue ;;
  esac
  sources+=("$file")
done < <(rg --files "$ROOT/native/Sources/History" -g '*.swift' | sort)
xcrun swiftc -O -parse-as-library -module-name RealHistoryBenchmark \
  -module-cache-path "$ROOT/native/build/history-benchmark-module-cache" \
  "${sources[@]}" "$ROOT/native/Scripts/benchmark-real-history.swift" \
  -o "$bundle/Contents/MacOS/history-benchmark"
codesign --force --sign - "$bundle" >/dev/null 2>&1
if [[ "${1:-}" == --compile-only ]]; then
  [[ "$#" == 1 ]] || { echo '--compile-only cannot be combined with a benchmark run' >&2; exit 1; }
  echo '{"phase":"compile_complete","real_history_scanned":false,"catalog_opened":false}'
  exit 0
fi
TMPDIR="$work" CCBUD_BENCHMARK_SCRATCH="$work" \
  CCBUD_BENCHMARK_BUILD_ROOT="$ROOT/native/build" \
  "$bundle/Contents/MacOS/history-benchmark" "$@"
