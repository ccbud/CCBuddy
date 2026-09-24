# CCbuddy

CCbuddy is an AI coding workspace rebuilt on CCbuddy. It retains the desktop, web, and CLI Agent foundation and adds a read-only local history reader with a cross-project calendar timeline for Claude Code, Codex CLI, Qoder CLI, Grok Build, GitHub Copilot CLI, and Antigravity CLI sessions.

The former CCbuddy gateway, provider configuration, plugin and Skills management, usage monitoring, session mutation, import/export, and resume features are not carried over. The history reader never changes producer transcripts or CLI configuration.

Configure your model provider URL and API key in Settings after launch. No CCbuddy account or cloud endpoint is required. Local workspaces work by default; remote workspaces need an explicitly configured CCbuddy-owned runtime asset source as shown in [.env.example](.env.example).

Use Node.js 24.14.0 and pnpm 10.33.2, as specified in [mise.toml](mise.toml).

```bash
pnpm install
pnpm bootstrap
pnpm dev:desktop:test
```

Open the read-only history window from the desktop application menu. The original CCbuddy Agent workspace remains available. For web development run `pnpm dev:web`. After `pnpm bootstrap`, run `pnpm ccbuddy --version` at the repository root; the CLI package in [apps/ccbuddy-cli](apps/ccbuddy-cli) also declares a `ccbuddy` executable alias.

Validation: `pnpm typecheck`, `pnpm lint`, and `pnpm architecture:check --changed`. See the [history spec](docs/specs/history-review.md) for behavior and ownership.

This derivative retains CCbuddy's Apache-2.0 [license](LICENSE), [notices](NOTICE.md), and [third-party notices](THIRD-PARTY-NOTICES.md). The prior CCbuddy Swift implementation was not copied into this application. Codex and Grok Build source code was not copied.
