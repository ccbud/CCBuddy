# CC Buddy Gateway Helper

`ccbud-gateway` is the headless localhost gateway used by the native SwiftUI application. It keeps
the proxy data plane in Rust while leaving configuration ownership and process supervision to the
app.

Run it with a private (owner-only) JSON configuration file:

```sh
ccbud-gateway --config /path/to/gateway.json
```

Use `ccbud-gateway --version` for a config-free packaged-binary identity check, or append
`--check-config` to validate a private configuration without starting either listener.

The process prints one JSON `ready` event to stdout after both listeners bind. The public listener
accepts inference traffic only on `127.0.0.1`; the separate management listener exposes authenticated
health, status, and bounded monitor-log APIs.

When failover is enabled, routing follows `failover.providerIds` exactly; `activeProviderId` is
used only when failover is disabled. Anthropic hosted WebSearch is bridged to OpenAI Responses,
including direct-caller validation, history replay, citations, usage, and `max_uses` enforcement.
