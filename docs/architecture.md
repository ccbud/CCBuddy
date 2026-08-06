# Architecture

CC Buddy is a Tauri app: a Rust backend (`src-tauri/`) and a plain-ESM renderer (`src/renderer/`)
with no bundler. This document records the two rules that shape the codebase.

## Rule 1 — no source file over 220 lines

Enforced by `test/file-size.test.js` (part of `npm test`). Vendored bundles, the generated
`styles.css` and the build-synced `src/renderer/shared/` copy are exempt; everything else is
hand-maintained source and must stay under the limit. Reaching for a split is the intended
response, not raising the number.

The corollary is a module per responsibility. Where a file would otherwise grow, it becomes a
directory module (`foo.rs` → `foo/mod.rs` + siblings; a view → `views/<name>/index.js` + siblings)
whose `mod.rs` / `index.js` is the only public surface.

## Rule 2 — nothing on the cold-start path that a later click could load

**Backend.** `setup()` in `src-tauri/src/lib.rs` only builds the window, tray and event hooks.
Every filesystem-heavy boot step — one-time `historyDirs` migrations, plugin reconcile, CLI
connection repair, gateway and plugin start, history-watcher registration, usage-cache warm —
runs off the main thread from `startup::spawn_background_boot`, in the same order as before.
The window paints and accepts input while that work proceeds.

**Renderer.** `index.html` ships the shell plus the first view (服务) only. `js/main.js` and the
`js/core/` modules it imports are the only JavaScript parsed before first paint:

| Loaded at startup | Loaded on demand |
| --- | --- |
| shell markup + 服务 view | 插件 / 监控 / 设置 / 会话 markup and modules (`views/registry.js`) |
| active locale's dictionary parts | the other four locales (`shared/i18n/parts.js` manifest) |
| `theme-boot.js` (pre-paint theme/lang stamp) | `marked` + `highlight.js` (`core/loader.js`, on first transcript or inspector open) |
| analytics queue stub (deferred) | provider modal, request-inspector drawer, plugin forms |

Two idle prefetches warm the heaviest lazy paths (vendor bundles, the 会话 view) after boot, so
the first click still feels instant without costing startup.

## Module map

```
src/renderer/
  js/core/      bridge (IPC) · state · i18n · loader · dom · icons · theme · toast
  js/views/     registry + providers/ plugins/ monitor/ settings/ conversations/
  js/popover/   tray usage window
  css/          numbered partials; input.css is the @import manifest (order = cascade order)
src/shared/i18n/  per-language, per-domain dictionary parts + index (Node) / parts.js (browser)
src-tauri/src/    startup · gateway/ · history/ · protocol/ · codex/ · store · usage · plugin · …
```

## Testing

- `npm test` — i18n dictionary parity across locales, part-manifest integrity, file-size rule.
- `cd src-tauri && cargo test` — the gateway, history, usage, export and protocol engines.
