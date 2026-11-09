# gen-ui-protocol

Pure wire contracts for generated conversation UI. A reference identifies an executor-side file;
it does not grant file access. The target Host authorizes and normalizes paths. Workspace identity
and session isolate state. A state update replaces a JSON snapshot of at most 16 KiB. Only
modelContent can enter bounded, untrusted model context. No MCP plugin identity or tool permission
is implied by a generated UI reference.

`selectGenUiModelContext` returns validated `{ path, state }` snapshots containing
modelContent only. `sendText.genUiContext` and its canonical intent persist this
separately from visible text; explicit `[]` distinguishes literal user text from
legacy tail encoding. Limits are 100 entries, 16 KiB per state and 64 KiB overall.
An executor derives untrusted user-side reminders from input metadata after
provider reordering; state is never an independent canonical history attachment.

`ccbuddy/genUiStyles` carries string CSS variables restricted to the `--gen-ui-*`
namespace in HostContext. Standard MCP style variables remain SDK-validated and
separate. This presentation extension changes no session or task state. See
`docs/specs/upstream-v3.17.2-integration.md`.

Tweak messages follow the upstream registration/update/disposal and ACK lifecycle. Each registration identifies one DOM target and at most 12 typed controls; preview changes carry registrationId, targetId, callback and previousValue. The page owner accepts at most 64 live registrations. This private Gen UI method grants no generic tool access.
