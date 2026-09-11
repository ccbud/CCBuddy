<div align="center">

<img src="docs/img/icon.png" alt="CC Buddy" width="120" height="120" style="border-radius: 26px; box-shadow: 0 12px 32px rgba(0,0,0,0.18);">

# CC Buddy

**Manage and review completed Coding Agent CLI sessions.**

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20Universal-5b6cff?style=flat-square&logo=apple&logoColor=white)](#installation) [![Built with SwiftUI](https://img.shields.io/badge/built%20with-SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-3b82f6?style=flat-square)](./LICENSE)

[Download](https://github.com/ccbud/ccbud/releases) · **English** · [简体中文](./README.zh-CN.md)

</div>

---

**CC Buddy** is a native macOS app for managing and reviewing local Coding Agent CLI sessions. It does not run the agent for you; it turns histories already written by your CLIs into readable, searchable timelines. After a task finishes, you can trace its goal, decisions, tool calls, subagents, changes, failures, and final outcome. An optional local gateway is included for model API conversion.

```text
CLI session histories ──▶ CC Buddy ──▶ browse · search · trace · export · review
```

## Session review

Reads local histories from **Claude Code, Codex CLI, Qoder CLI, Grok Build CLI, GitHub Copilot CLI, and Antigravity CLI**.

- **Reconstruct the run** — render Markdown, thinking, tool calls and results, patches, images, recorded model/token metadata, and main/subagent threads.
- **Find the moment** — auto-discover histories, group by source and project, and search across sessions or inside one conversation.
- **Manage the archive** — rename, tag, star, filter, recycle, follow active sessions, and import compatible JSONL/ZIP transcripts. History roots are managed in Settings › Session locations.
- **Pick it back up** — reopen a session in Terminal, iTerm, Ghostty or Warp with the producing CLI's own resume flags; export raw session files/bundles (JSONL, ZIP, or DB) or portable HTML; hand the main and subagent transcripts to Claude or ChatGPT for analysis.

## Fast search, local intelligence

- **Embedded tgrep, without a conversation SQLite database** searches independently compressed file packs. Queries never wait for index preparation: direct block search returns verified results while tgrep prepares in the background, then narrows subsequent searches. Exact Unicode verification preserves snippets, message positions and occurrence counts. The search palette reports real progress and latency. [Architecture and real-history measurements](docs/search-performance.md).
- **Apple Neural Engine through Core ML** powers optional offline semantic ordering of the first 32 results for English and code queries. A bundled 22.6 MB MiniLM weight file needs no account or download. Keyword results appear first and remain available while the model prepares; disabling smart ordering restores their original order. Intel uses CPU inference, and non-Latin queries keep keyword order.

On an Apple M4, Core ML's compute plan preferred ANE for 147 of 155 reported operations. A warm new-query rerank with three cached candidates took a median 0.774 ms versus 1.836 ms on CPU in the recorded run. The interface distinguishes anticipated placement from hardware-utilization telemetry. See [model details, limitations and reproducible measurements](native/SEMANTIC_SEARCH.md).

## A renewed Mac workspace

A floating navigation rail, layered search palette, quieter transcript cards and focus reading bring the library, conversation and inspector into a clearer workspace. Native glass is used on macOS 26+, with material or opaque fallbacks for earlier systems and accessibility preferences. Motion respects Reduce Motion; surfaces respect Reduce Transparency and Increase Contrast.

Press **⌘K** to search, **↑ / ↓** to choose a result and **Return** to open it. **⌘⇧S** toggles focus reading, **⌘1–6** switches workspaces, **⌘R** refreshes the conversation index and **⌘,** opens Settings.

The redesign follows a macOS 27 design direction using available macOS 26 APIs behind availability checks. It does not require macOS 27 or claim validation on that OS.

## Included: local API gateway

As a companion feature, the gateway accepts **Anthropic Messages**, **OpenAI Chat Completions**, and **OpenAI Responses** from clients, whichever of those three you configure as upstreams.

A provider is one root address — `https://api.deepseek.com` — and up to three addresses bound under it, one per protocol:

| Protocol | Address |
| --- | --- |
| Anthropic Messages | `https://api.deepseek.com/anthropic` |
| OpenAI Chat Completions | `https://api.deepseek.com/chat/completions` |
| OpenAI Responses | `https://api.deepseek.com/responses` |

- **Bind all three** and every client is handed to the address that already speaks its protocol, untouched. A vendor publishing all three of its own endpoints is never translated for.
- **Bind one or two** and a client speaking a protocol you did bind still passes through, while one speaking a protocol you did not is converted for you. Conversion follows what you configured, rather than being decided in advance.

Either way, if an upstream fails the rest of your queue takes over in order. It configures **Claude Code and Codex** with one click; other compatible clients can use the local endpoint manually. Presets ship for Anthropic, OpenAI, Google and the model vendors with a first-party coding endpoint, alongside custom and plugin-backed providers, with switching and model mapping. A provider that publishes `/v1/models` or `/models` can fill in its own model bindings from the editor; one that does not leaves the control disabled rather than failing.

The gateway binds to `127.0.0.1`; inference requests still go to the provider you select.

## Installation

CC Buddy 2.x supports **Macs running macOS 13 or newer**, Apple silicon and Intel alike. Download the signed universal DMG from [Releases](https://github.com/ccbud/ccbud/releases).

Version 2 is the native Swift/SwiftUI replacement and does not publish Windows or Linux builds. Legacy 1.x artifacts remain available on the Releases page, but those platforms do not receive the 2.x application or updater channel.

Homebrew:

```bash
brew install --cask ccbud/tap/ccbud
```

## Development

Native development requires Xcode 26, XcodeGen, Python 3 and a current Rust stable toolchain installed through [rustup](https://rustup.rs/). Node.js is used by localization and release tooling. End users do not need these tools.

```bash
git clone https://github.com/ccbud/ccbud.git && cd ccbud
brew install xcodegen
native/Scripts/fetch-bifrost.sh
bash native/Scripts/build-tgrep.sh
python3 native/Scripts/verify-semantic-model.py
xcodegen generate --spec native/project.yml --project native
xcodebuild -project native/CCBuddy.xcodeproj -scheme CCBuddy \
  -destination 'platform=macOS' build
```

The helper scripts build for the current Mac; release builds bundle both arm64 and x86_64. No local tgrep checkout is required: Cargo pins the upstream revision and dependency lockfile.

### Releases

Every push to `main`, including PR merges and direct pushes, starts the official release pipeline. No manual tag is needed. The workflow creates an immutable snapshot of that exact source commit with only synchronized version-field changes, allocates the next patch version, and pushes an annotated tag. It does not write bot version commits back to `main`.

The same workflow then runs shared and native unit/UI tests, builds the universal app, signs it with Developer ID, notarizes it with Apple, and publishes a complete GitHub Release containing the DMG, updater archive, signature, and `latest.json`. Failed checks leave the release unpublished; rerun the failed Actions jobs to resume.

Retries reuse the source commit's existing tag. Consecutive pushes queue serially (GitHub permits up to 100 pending runs); a late older source cannot replace the latest updater channel or Homebrew cask. Explicit `vX.Y.Z` tag pushes remain supported. See the [release workflow](.github/workflows/release.yml).

See the [native build and test guide](native/README.md) for universal builds, isolated unit/integration tests and UI tests with a separate bundle identifier. The [architecture guide](docs/architecture.md) maps the native modules, data flow and compatibility boundaries.

## License

Released under [GPL-3.0](./LICENSE).
