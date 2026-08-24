# CC Buddy Native

This directory is the macOS-native replacement for the legacy Tauri application. It uses
SwiftUI/AppKit for the product surface, preserves the existing `~/.ccbud/config.json` schema, and
supervises the bundled `ccbud-gateway` Rust helper for local LLM gateway traffic. The helper follows
the core proxy architecture of cc-switch while keeping configuration and lifecycle ownership in the
native app.

Build the locked arm64 helper, generate the project, and build the app:

```bash
cd native
./Scripts/build-gateway-helper.sh
xcodegen generate
xcodebuild -project CCBuddy.xcodeproj -scheme CCBuddy \
  -destination 'platform=macOS,arch=arm64' build
```

`build-gateway-helper.sh` requires an Apple-silicon Mac and Rust 1.88 or newer. It runs Cargo in
locked release mode and installs the verified result at `Vendor/ccbud-gateway`. The Xcode copy phase
then embeds that binary at `CC Buddy.app/Contents/MacOS/ccbud-gateway`.

Run unit/integration tests with isolated application and CLI configuration roots. Supplying the
three explicit binaries makes the real loopback gateway, Codex, and Claude E2Es mandatory instead
of skippable:

```bash
test_root="$(mktemp -d "${TMPDIR:-/tmp}/ccbud-native-tests.XXXXXX")"
mkdir -p "$test_root/ccbud" "$test_root/claude" "$test_root/codex"
CCBUD_HOME="$test_root/ccbud" \
CCBUD_CLAUDE_SETTINGS="$test_root/claude/settings.json" \
CCBUD_CODEX_CONFIG="$test_root/codex/config.toml" \
CCBUD_GATEWAY_BINARY="$PWD/Vendor/ccbud-gateway" \
CCBUD_CODEX_BINARY="$(command -v codex)" \
CCBUD_CLAUDE_BINARY="$(command -v claude)" \
xcodebuild -project CCBuddy.xcodeproj -scheme CCBuddy \
  -destination 'platform=macOS,arch=arm64' -only-testing:CCBuddyTests \
  -parallel-testing-enabled NO test
```

`CCBUD_GATEWAY_BINARY` is a development and test override. Production launches resolve only the
bundled helper.

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

Run the helper's Rust tests independently with:

```bash
cargo test --locked --manifest-path GatewayHelper/Cargo.toml
```

## Gateway log privacy

The monitor inspector reads a bounded, in-memory ring of request records from the authenticated
loopback management listener. Credential-bearing headers are redacted, captured payloads are
truncated at the helper's safety limit, and all records disappear when the helper exits. Prompt and
response bodies may still contain sensitive content, so management credentials and the generated
owner-only configuration must remain private.

## Attribution

The gateway helper derives part of its architecture and implementation from cc-switch. Its upstream
MIT notice is maintained in `GatewayHelper/NOTICE` and ships byte-for-byte in the app as
`CCBuddyGateway-NOTICE.txt`. Locked Rust dependency licenses are generated with
`node Scripts/generate-gateway-third-party-notices.mjs`, checked into
`GatewayHelper/THIRD-PARTY-NOTICES.txt`, and bundled as
`CCBuddyGateway-THIRD-PARTY-NOTICES.txt`. Release verification also checks the project GPL license
and the bundled Wake and Zstandard notices.
