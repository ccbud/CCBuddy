# CC Buddy Native

This is the shipping CC Buddy 2.x application: SwiftUI/AppKit, macOS 13+, with universal
arm64 and x86_64 releases. It preserves the `~/.ccbud/config.json` schema and supervises
Maxim Bifrost's `bifrost-http` executable for gateway traffic. The legacy Tauri directories
are retained for compatibility tests and older releases; they do not render the native app.

## Search and interface

Full-text search embeds a pinned Rust [tgrep](https://github.com/microsoft/tgrep) library.
Its trigram candidates are checked against original text, preserving matching semantics,
snippets and transcript positions. Catalog revisions update the index incrementally;
SQLite provides the fallback. The palette exposes the active engine and query timing.

Optional smart ordering runs a bundled MiniLM Core ML model on the first 32 candidates
for English and code queries. Keyword results are published before inference and remain
available during the one-time model preparation. Disabling smart ordering restores the
original order. Apple Silicon permits CPU + Neural Engine scheduling; Intel uses CPU.
Non-Latin queries preserve keyword ordering. The model and tokenizer ship offline, and
no query or vector is sent to a provider. [Model details and benchmarks](SEMANTIC_SEARCH.md)
explain the 512-entry cache, cold-start cost, language limits and anticipated compute plan.

The refreshed workspace uses a floating rail, layered search, focused transcript reading,
and native glass on macOS 26+. Older systems and accessibility preferences receive material
or opaque fallbacks. Reduce Motion, Reduce Transparency and Increase Contrast remain part
of the design contract. The macOS 27 design direction uses available macOS 26 APIs behind
availability checks; it is not a claim of macOS 27 testing or a new minimum OS requirement.

| Shortcut | Action |
| --- | --- |
| ⌘K | Open or dismiss conversation search |
| ↑ / ↓, Return, Escape | Select, open or dismiss a search result |
| ⌘⇧S | Toggle focused transcript reading |
| ⌘1–6 | Conversations, timeline, providers, monitor, Skills, plugins |
| ⌘R | Refresh the conversation index |
| ⌘F | Find within the current transcript |
| ⌘, | Open Settings |

See [the architecture guide](../docs/architecture.md) for ownership and data flow.

## Build

Install Xcode 26 and select its developer directory, XcodeGen, Python 3, and current Rust
stable through [rustup](https://rustup.rs/). Node.js is required for localization/release
tooling and CLI integration fixtures. CI pins Xcode 26.6, XcodeGen 2.46.0 and Rust 1.98.0.
Python conversion packages are only needed when regenerating the model, not to build it.

From the repository root:

```bash
brew install xcodegen
native/Scripts/fetch-bifrost.sh
bash native/Scripts/build-tgrep.sh
python3 native/Scripts/verify-semantic-model.py
xcodegen generate --spec native/project.yml --project native
xcodebuild -project native/CCBuddy.xcodeproj -scheme CCBuddy \
  -destination 'platform=macOS' build
```

The helper scripts default to the host architecture. Cargo uses the exact upstream tgrep
revision and checked-in lockfile; no developer checkout or installed tgrep CLI is used.
Xcode bundles the signed dylib under `Contents/Frameworks` and compiles the checked-in
`.mlpackage` into an offline `.mlmodelc`. The verifier checks model/tokenizer/license
checksums using Python's standard library.

Prepare both helper architectures before a universal build:

```bash
CCBUD_BIFROST_ARCH=universal native/Scripts/fetch-bifrost.sh
CCBUD_TGREP_ARCH=universal bash native/Scripts/build-tgrep.sh
xcodebuild -project native/CCBuddy.xcodeproj -scheme CCBuddy \
  -configuration Release -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
```

The release pipeline also validates nested signatures, architecture slices, deployment
targets and required resources. Its entry points are `Scripts/build-native-release.sh`,
`Scripts/verify-release-app.sh` and `Scripts/package-native-release.sh`.

## Unit and integration tests

These commands run from `native/` after preparing the helpers and generating the project.
Use isolated application and CLI configuration roots. Supplying all three explicit
binaries makes real loopback Bifrost, Codex and Claude E2Es mandatory instead of skippable:

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
  -destination "platform=macOS,arch=$(uname -m)" -only-testing:CCBuddyTests \
  -parallel-testing-enabled NO test
```

The native suite includes real bundled-model inference, CPU parity, tokenizer golden data,
semantic cancellation and cache behavior, tgrep/SQLite result parity, incremental indexing,
scope isolation, and the existing gateway, plugin, Skills, history, export and update tests.
Test the Rust bridge and verify model artifacts separately from the repository root:

```bash
cargo test --locked --manifest-path native/TgrepBridge/Cargo.toml
python3 native/Scripts/verify-semantic-model.py
```

## UI tests

Run UI tests from `native/` under their own application identifier. A separate identifier is
required when a production CC Buddy is installed or running, because `XCUIApplication.terminate()` operates by
bundle identifier — but keep it *stable* rather than generating one per run: every new identifier
is a new TCC subject, and each first launch then asks for consent that nobody is there to give.

```bash
xcodebuild -project CCBuddy.xcodeproj -scheme CCBuddy \
  -destination "platform=macOS,arch=$(uname -m)" -only-testing:CCBuddyUITests \
  -parallel-testing-enabled NO -maximum-parallel-testing-workers 1 \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO \
  CCBUD_PRODUCT_BUNDLE_IDENTIFIER="dev.ccbud.gateway.uitest.local" test
```

`CODE_SIGN_IDENTITY=-` and `ENABLE_HARDENED_RUNTIME=NO` are what CI uses; without them the runner
refuses to inject its library into an app signed by a different team. A local run also has to
answer one macOS prompt to enable UI automation, which CI does not.

If the runner hangs before connecting, inspect its `.xcresult` diagnostics and any pending
macOS UI-automation consent before rerunning. Keep the local test identifier stable so each
run does not create a new privacy-permission identity.

The PR workflow runs the full native unit and UI suites with zero skipped tests, then builds
an unsigned universal package and exercises its packaged self-check and single-instance
handoff. The workflow also retains JavaScript and legacy Rust compatibility tests.

## Bifrost helper

The app resolves Bifrost in this order: `CCBUD_BIFROST_BINARY`, an executable bundled in the app,
then `native/Vendor/bifrost-http`. Release builds will bundle the pinned sidecar; local UI work can
set the environment variable to any compatible Bifrost build.

The fetcher pins Bifrost HTTP `v1.6.11` and verifies both published architecture hashes.
For the Intel slice it corrects the upstream Mach-O SDK metadata before signing, verifying
the normalized hash as well. The executable code and deployment target are unchanged.

## Gateway log privacy

The monitor inspector requires Bifrost to persist structured inference logs and provider-wire raw
request/response payloads in its app-private local SQLite database. Generated configuration applies
Bifrost's minimum one-day retention threshold through `client.log_retention_days`. Bifrost prunes
expired rows at startup and then approximately daily, so deletion is asynchronous rather than an
exact 24-hour guarantee. In Bifrost v1.6.11, `logs_store.retention_days` controls ClickHouse TTL and
does not control the SQLite cleaner.
