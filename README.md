<div align="center">

<img src="docs/img/icon.png" alt="CC Buddy" width="120" height="120" style="border-radius: 26px; box-shadow: 0 12px 32px rgba(0,0,0,0.18);">

# CC Buddy

**Manage and review completed Coding Agent CLI sessions.**

[![Platform](https://img.shields.io/badge/platform-macOS%20%C2%B7%20Windows%20%C2%B7%20Linux-5b6cff?style=flat-square)](#installation) [![Built with Tauri](https://img.shields.io/badge/built%20with-Tauri-24C8DB?style=flat-square&logo=tauri&logoColor=white)](https://tauri.app/) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-3b82f6?style=flat-square)](./LICENSE)

[Download](https://github.com/ccbud/ccbud/releases) · **English** · [简体中文](./README.zh-CN.md)

</div>

---

**CC Buddy** is a cross-platform desktop app for managing and reviewing local Coding Agent CLI sessions. It does not run the agent for you; it turns histories already written by your CLIs into readable, searchable timelines. After a task finishes, you can trace its goal, decisions, tool calls, subagents, changes, failures, and final outcome. An optional local gateway is included for model API conversion.

```text
CLI session histories ──▶ CC Buddy ──▶ browse · search · trace · export · review
```

## Session review

Reads local histories from **Claude Code, Codex CLI, Qoder CLI, Grok Build CLI, GitHub Copilot CLI, and Antigravity CLI**.

- **Reconstruct the run** — render Markdown, thinking, tool calls and results, patches, images, recorded model/token metadata, and main/subagent threads.
- **Find the moment** — auto-discover histories, group by source and project, and search across sessions or inside one conversation.
- **Manage the archive** — rename, tag, filter, recycle, add custom history roots, follow active sessions, and import compatible JSONL/ZIP transcripts.
- **Continue the review** — export raw session files/bundles (JSONL, ZIP, or DB) or portable HTML; on macOS, open the main and subagent transcripts in Claude or ChatGPT for analysis.

## Included: local API gateway

As a companion feature, the gateway accepts **Anthropic Messages**, **OpenAI Chat Completions**, and **OpenAI Responses** on both client and provider sides, passing through matching protocols or translating between them. It configures **Claude Code and Codex** with one click; other compatible clients can use the local endpoint manually. Preset, custom, and plugin-backed providers support switching and model mapping.

The gateway binds to `127.0.0.1`; inference requests still go to the provider you select.

## Installation

Download the latest build for macOS, Windows, or Linux from [Releases](https://github.com/ccbud/ccbud/releases).

Homebrew (macOS):

```bash
brew install --cask ccbud/tap/ccbud
```

## Development

With Node.js and the [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/) installed:

```bash
git clone https://github.com/ccbud/ccbud.git && cd ccbud
npm install && npm start
```

## License

Released under [GPL-3.0](./LICENSE).
