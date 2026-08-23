# CC Buddy Native

This directory is the macOS-native replacement for the legacy Tauri application. It uses
SwiftUI/AppKit for the product surface, preserves the existing `~/.ccbud/config.json` schema,
and supervises Maxim Bifrost's `bifrost-http` executable for all LLM gateway traffic.

Generate and build the project:

```bash
cd native
xcodegen generate
xcodebuild -project CCBuddy.xcodeproj -scheme CCBuddy -destination 'platform=macOS' build
```

Run unit/integration tests with an isolated application and CLI configuration root. Supplying all
three explicit binaries makes the real loopback Bifrost, Codex, and Claude E2Es mandatory instead
of skippable:

```bash
test_root="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-native-tests.XXXXXX")"
mkdir -p "$test_root/ccbud" "$test_root/claude" "$test_root/codex"
CCBUD_HOME="$test_root/ccbud" \
CCBUD_CLAUDE_SETTINGS="$test_root/claude/settings.json" \
CCBUD_CODEX_CONFIG="$test_root/codex/config.toml" \
CCBUD_BIFROST_BINARY="$PWD/Vendor/bifrost-http" \
CCBUD_CODEX_BINARY="$(command -v codex)" \
CCBUD_CLAUDE_BINARY="$(command -v claude)" \
xcodebuild -project CCBuddy.xcodeproj -scheme CCBuddy \
  -destination 'platform=macOS,arch=arm64' -only-testing:CCBuddyTests \
  -parallel-testing-enabled NO test
```

Run UI tests under a unique application identifier. This is required when a production CC Buddy
with `dev.ccbud.gateway` is installed or running, because `XCUIApplication.terminate()` operates
by bundle identifier:

```bash
ui_suffix="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
xcodebuild -project CCBuddy.xcodeproj -scheme CCBuddy \
  -destination 'platform=macOS,arch=arm64' -only-testing:CCBuddyUITests \
  -parallel-testing-enabled NO \
  CCBUD_PRODUCT_BUNDLE_IDENTIFIER="dev.ccbud.gateway.uitest.$ui_suffix" test
```

The app resolves Bifrost in this order: `CCBUD_BIFROST_BINARY`, an executable bundled in the app,
then `native/Vendor/bifrost-http`. Release builds will bundle the pinned sidecar; local UI work can
set the environment variable to any compatible Bifrost build.

The development fetcher pins Bifrost HTTP `v1.6.11` and verifies the published arm64 SHA-256 before
installing it locally:

```bash
./Scripts/fetch-bifrost.sh
CCBUD_BIFROST_BINARY="$PWD/Vendor/bifrost-http" xcodebuild \
  -project CCBuddy.xcodeproj -scheme CCBuddy -destination 'platform=macOS' build
```

## Gateway log privacy

The monitor inspector requires Bifrost to persist structured inference logs and provider-wire raw
request/response payloads in its app-private local SQLite database. Generated configuration applies
Bifrost's minimum one-day retention threshold through `client.log_retention_days`. Bifrost prunes
expired rows at startup and then approximately daily, so deletion is asynchronous rather than an
exact 24-hour guarantee. In Bifrost v1.6.11, `logs_store.retention_days` controls ClickHouse TTL and
does not control the SQLite cleaner.
