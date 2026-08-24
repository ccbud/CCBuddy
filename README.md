<div align="center">

<img src="docs/img/icon.png" alt="CC Buddy" width="120" height="120" style="border-radius: 26px; box-shadow: 0 12px 32px rgba(0,0,0,0.18);">

# CC Buddy

**Manage and review completed Coding Agent CLI sessions.**

[![Platform](https://img.shields.io/badge/platform-macOS%20Apple%20silicon-5b6cff?style=flat-square&logo=apple&logoColor=white)](#installation) [![Built with SwiftUI](https://img.shields.io/badge/built%20with-SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-3b82f6?style=flat-square)](./LICENSE)

[Download](https://github.com/ccbud/ccbud/releases) · **English** · [简体中文](./README.zh-CN.md)

</div>

---

**CC Buddy** is a native macOS app for managing and reviewing local Coding Agent CLI sessions. It does not run the agent for you; it turns histories already written by your CLIs into readable, searchable timelines. After a task finishes, you can trace its goal, decisions, tool calls, subagents, changes, failures, and final outcome. An optional local gateway is included for model API conversion.

```text
CLI session histories ──▶ CC Buddy ──▶ browse · search · trace · export · review
```

## Session review

Reads local histories from **Claude Code, Codex CLI, Qoder CLI, Grok Build CLI, DSH, Cursor, OpenCode, Pi, OMP, Kiro, Kimi, Gemini CLI, GitHub Copilot CLI, and Antigravity CLI**.

- **Reconstruct the run** — render Markdown, thinking, tool calls and results, patches, images, recorded model/token metadata, and main/subagent threads.
- **Find the moment** — auto-discover histories, group by source and project, and search across sessions or inside one conversation.
- **Manage the archive** — rename, tag, filter, recycle, add custom history roots, follow active sessions, and import compatible JSONL/ZIP transcripts.
- **Continue the review** — export raw session files/bundles (JSONL, ZIP, or DB) or portable HTML; on macOS, open the main and subagent transcripts in Claude or ChatGPT for analysis.

## Included: local API gateway

As a companion feature, the gateway accepts **Anthropic Messages**, **OpenAI Chat Completions**, and **OpenAI Responses** on both client and provider sides, passing through matching protocols or translating between them. It configures **Claude Code and Codex** with one click; other compatible clients can use the local endpoint manually. Preset, custom, and plugin-backed providers support switching and model mapping.

The gateway binds to `127.0.0.1`; inference requests still go to the provider you select.

## Installation

CC Buddy 2.x supports **Apple-silicon Macs running macOS 13 or newer**. Download the signed arm64 DMG from [Releases](https://github.com/ccbud/ccbud/releases).

Version 2 is the native Swift/SwiftUI replacement and does not publish Intel Mac, Windows, or Linux builds. Legacy 1.x artifacts remain available on the Releases page, but those platforms do not receive the 2.x application or updater channel.

Homebrew (Apple silicon):

```bash
brew install --cask ccbud/tap/ccbud
```

## Development

Native development requires Xcode 26, XcodeGen 2.46.0, and Rust 1.88 or newer. Node.js is used by localization and release tooling.

```bash
git clone https://github.com/ccbud/ccbud.git && cd ccbud
brew install xcodegen
native/Scripts/build-gateway-helper.sh
xcodegen generate --spec native/project.yml --project native
xcodebuild -project native/CCBuddy.xcodeproj -scheme CCBuddy \
  -destination 'platform=macOS,arch=arm64' build
```

See [`native/README.md`](native/README.md) for the isolated unit/integration command and the
unique-bundle-ID UI test command. The latter keeps an installed CC Buddy process out of XCTest's
launch and termination scope.

## License

Released under [GPL-3.0](./LICENSE). The app bundle also includes the required cc-switch, Wake,
and Zstandard attribution notices.
