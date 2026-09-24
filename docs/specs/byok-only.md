# User-configured model services only

The new CCbuddy does not use the upstream foundation project's cloud account,
model gateway, or subscription. The desktop app, Web app, and CLI start without
application sign-in or a remote application-configuration request. A fresh profile has no selected model;
the Agent asks the user to configure a model service before sending a turn.
History review remains available without a model configuration.
When a chat turn has no usable model, the banner offers only the model-service
settings action; it never offers account login or a plan upgrade.

Users may add their own endpoint and credential, including a provider template
that requires their own API key. Such requests go directly to the endpoint the
user configured. Built-in account-backed provider entries, automatic upstream
provider CDN refresh, upstream login/purchase links, and a default application
endpoint are not part of the new CCbuddy. No fallback to an upstream account or bundled
credential is allowed when a user configuration is missing or invalid.

The provider configuration runtime owns the merged read model. Its bundled
template layer is a local static file; the personal layer under
`~/.ccbuddy/v2` owns user selections and credentials. The UI is a projection
and only sends explicit configuration commands. The Agent runtime receives the
selected provider snapshot; it cannot silently switch to a different account.
The services assembly owns a closed application-cloud API port: inherited
OAuth, subscription, quota, sharing, client-configuration, and feedback calls
cannot send a request to an upstream account endpoint, including through an
old RPC caller. This port is separate from the Agent's selected user-provider
transport. OAuth discovery returns no providers and starting a login fails
closed. A built-in configuration refresh only rereads local bundled data.
The retired cloud client-scene catalog returns an empty local list, so the
workbench and automation templates do not keep requesting an unavailable cloud
endpoint. Manual task and automation entry points remain available.
The desktop-attached remote workspace Host uses the same closed cloud API,
disabled OAuth service, and disabled conversation-sharing service. Connecting
to a remote workspace cannot re-enable the retired account network path.

```text
local CCbuddy templates + user's config -> provider snapshot -> selected model
                                                       ├─ absent: setup required
                                                       └─ present: direct user endpoint request
```

Acceptance: (1) with a fresh `~/.ccbuddy`, no application login or remote
configuration request occurs before opening the workbench/history; (2) bundled
account-backed provider rules are absent; (3) missing model configuration
produces a clear setup state, not an account login; (4) a user-added API endpoint
remains available after restart and is the only model request destination;
(5) no startup or update path fetches the upstream release/config feed.
(6) invoking an inherited account or client-config RPC cannot cause an
outbound request, even when the UI entry point is hidden.
(7) the same RPCs remain closed in a remote workspace Host.
(8) opening a new chat with no configured model shows a setup message and a
model-settings action, with no subscription purchase action.
(9) local and remote Host client-scene list RPCs return an empty successful
catalog without an account request or retry loop.
The bundled template release contains no account-backed provider rules or
model metadata rules for the retired upstream account and off-peak gateways.
An actual request to a user-configured model endpoint carries only CCbuddy
client identity and request attribution. Its User-Agent, title, referer,
trace, and session-type headers must identify the new CCbuddy only.
Conversation sharing is disabled at the service boundary because it requires
an upstream account and writes artifacts into a workspace. Existing clients
receive a feature-disabled response; no share upload or project artifact is
created.
