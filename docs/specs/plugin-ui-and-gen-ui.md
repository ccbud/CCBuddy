# Plugin UI and Gen UI

## Product rule

CCbuddy Desktop can show interactive pages from two sources. They use
different protocols and their APIs must not be mixed.

**Plugin UI (MCP Apps).** An installed and enabled plugin whose MCP server
publishes `ui://` HTML resources may render them as tool-result cards or as
session side-pane surfaces declared in the manifest's `ui.surfaces`. Pages talk
to the host through the official `@modelcontextprotocol/ext-apps` SDK;
business data stays with the plugin's MCP server. Page-initiated tool calls
reuse the existing permission decision and approval flow and never create
transcript rows. Sampling from a page uses the model service the user
configured for the current task. There is no upstream account, official MCP
identity header or hosted model behind any of this: the protocol entrypoint
keeps the MCP elicitation and notification ports and does not wire the
upstream official-MCP auth block.

**Gen UI.** The Agent may generate an HTML page for the current answer. The
desktop hands the Agent a per-session output directory under the application
data root (`~/.ccbuddy/v2/visualizations/<scope hash>`); pages are never
written into the workspace, and the path helper rejects an output root inside
the workspace. Page state (`widgetState`) lives under the same root
(`gen-ui-state`), scoped by workspace identity and session; only
`modelContent` re-enters the model context. A follow-up message is sent only
after an explicit user action.

Interactive pages are a Desktop local-workspace capability. Web, mobile remote
control and remote workspaces keep ordinary MCP tool records and do not claim
these surfaces.

Pages run in a separate Electron sandbox (`persist:plugin-sandbox-v2-…`
partitions derived from the trusted plugin identity) with a per-resource CSP;
a plugin may only relax `unsafeEval` / `wasmUnsafeEval` through
`_meta["ccbuddy/csp"]`. Gen UI pages may load static assets only from the
fixed allowlist in `packages/shared/src/gen-ui/contract.ts` (public script
CDNs and font hosts). That allowlist is a page-authoring allowance, not an
application update or asset source: the runtime kit (`visualize.css`,
`visualize.html`, `calendar.js`, the tweak runtime, d3, lucide, floating-ui)
ships inside the bundled `visualize` plugin with SHA-256 values pinned in
`runtime-manifest.json` and `vendor/manifest.json`, and the desktop copies it
into the sandbox at build time. "Clear All Data" also clears the plugin
sandbox browser storage.

The bundled official plugin `visualize` is registered in
`official-plugin-definitions.ts` like the other official plugins: local
default icon, no CDN reference, marketplace `ccbuddy-plugins-official`.
Protocol methods, context keys, events, environment names and DOM globals use
the CCbuddy name (`ccbuddy/gen-ui/*`, `ccbuddy:set_globals`,
`window.ccbuddy`, `window.ccbuddyPluginSandbox`, `CCBUDDY_GEN_UI_*`).

This capability is ported from the upstream foundation project's UI-plugin
work on top of the current base, with the identity rules of
`product-branding.md` and the data rules of `product-data-isolation.md`
applied. The developer guide is `docs/ui-plugin.md`.

## Owners and event order

```text
manifest ui.surfaces / tool _meta.ui -> agent mcp-ui (bootstrap) -> plugin-ui-bridge (services)
  -> plugin-ui host (ui) -> pluginSandbox guest partition (desktop)
page callServerTool / sampling / app tools -> plugin-ui-bridge -> agent session
  -> existing permission + approval -> plugin MCP server / configured model service
agent answer + generated page -> ~/.ccbuddy/v2/visualizations/<scope> -> gen-ui host -> sandbox page
page setWidgetState -> ~/.ccbuddy/v2/gen-ui-state ; sendFollowUpMessage -> composer (user confirms)
```

Module boundaries are owned by `architecture-policy.yaml` (`mcp-apps-protocol`,
`mcp-ui`, `plugin-ui-bridge`, `plugin-sandbox`, `plugin-ui`,
`gen-ui-protocol`, `gen-ui-service`, `gen-ui`) and each module's
`CONTRACT.md`. `packages/services/src/paths.ts` still owns the data root; the
Gen UI service derives its output and state roots from it and the desktop
passes the output root to the Agent through `CCBUDDY_GEN_UI_OUTPUT_ROOT`.

## Acceptance

1. `pnpm typecheck`, the CLI workspace typecheck, `pnpm lint`,
   `pnpm fmt:check` and `pnpm architecture:check` pass.
2. The mcp-apps, plugin-ui, plugin-ui-bridge, pluginSandbox and gen-ui tests
   under `packages/{shared,services,ui,desktop,client}` and
   `apps/ccbuddy-cli/packages/{bootstrap,core,adapters}` pass, including
   `gen-ui-runtime-assets.test.ts` (pinned asset hashes) and
   `gen-ui-vendor-export.test.py`.
3. `node packages/desktop/scripts/gen-ui-e2e.mjs` (after a renderer build) and
   `node packages/desktop/scripts/mcp-apps-host-e2e.mjs` drive the Electron
   sandbox with the current source.
4. Gen UI output and state resolve below `~/.ccbuddy/v2`; a workspace path
   as output root is rejected. No page can reach Node, arbitrary files or
   another plugin's MCP server.
5. No string, protocol key, DOM global or file name introduced by this
   feature carries the upstream product name, and the plugin sandbox storage
   is removed by Clear All Data.
