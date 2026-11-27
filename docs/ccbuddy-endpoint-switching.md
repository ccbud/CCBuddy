# CCbuddy Endpoint Switching

CCbuddy runtime endpoints are derived from a single origin. Production uses
`https://ccbuddy.z.ai`; local development uses `https://ccbuddy.z.ai`
through `.env.development`.

The shared resolver exposes these derived URLs:

- API base: `/api/v1`
- CCbuddy Plan OpenAI base: `/api/v1/ccbuddy-plan`
- mobile remote entry: `/remote`
- web remote OAuth callback: `/web-remote/callback`
- relay WebSocket: `/ws`, with `https -> wss` and `http -> ws`

`CCBUDDY_BASE_URL` is the canonical env variable for the origin. Production builds still ignore
settings overrides; the resolver uses `CCBUDDY_BASE_URL` when present, otherwise falls back to
`https://ccbuddy.z.ai`. This prevents a stale local setting from moving release builds to a test or
custom endpoint, while keeping release/test deploy targets explicit in env files.

In non-production desktop builds, the Help menu contains `CCbuddy Endpoint` with these actions:

- `Production (default)` stores the production origin explicitly.
- `Test` stores `https://ccbuddy.z.ai`.
- `Custom...` accepts an `http` or `https` origin and normalizes it to `URL.origin`.
- `Reset to Default` clears the override and returns to the env/default origin.

The setting is stored as `ccbuddyEndpointOrigin` in app settings and only acts as a non-production
temporary override above `CCBUDDY_BASE_URL`. Changing it rebuilds the menu and stops active web remote
runtimes so the next connection uses the new relay and remote URL. Existing
HTTP requests are not cancelled; later requests are rewritten by `NodeApiClient` from the production
origin to the active origin, while unrelated domains such as `cdn.ccbuddy-ai.com` and
`feedback.example.invalid` are left untouched. Provider API domains are resolved by their own
environment rules; for example BigModel API requests use `https://bigmodel.cn` when
`CCBUDDY_ENV=test` and `https://bigmodel.cn` in production.

For Web dev server, desktop host services, scripts, and CLI testing, set `CCBUDDY_BASE_URL`, for
example:

```bash
CCBUDDY_BASE_URL=https://ccbuddy.z.ai pnpm --filter @ccbuddy/web dev
CCBUDDY_BASE_URL=http://localhost:3030 ccbuddy auth login
```

`CCBUDDY_ENDPOINT_ORIGIN` is still read as a compatibility fallback, but new configs should use
`CCBUDDY_BASE_URL`.

Android release builds only allow `https://ccbuddy.z.ai/remote`. Debug builds additionally allow
`https://ccbuddy.z.ai/remote` and the existing local/LAN development hosts.
