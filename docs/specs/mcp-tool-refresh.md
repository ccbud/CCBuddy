# MCP tool descriptor refresh

## Product rule

An MCP server's `notifications/tools/list_changed` notification takes effect at
the next agent turn boundary. Changes to any normalized `McpToolDescriptor`
field must refresh the runtime registry and invalidate its derived provider
tool cache, even when the tool name and description are unchanged. This
includes input schemas, annotations, model/app visibility, tool timeout and
UI metadata. The existing MCP result-envelope output schema remains unchanged;
this work does not introduce projection of the server's output schema.

Equivalent descriptor objects with different property insertion order or a
different tools-list order are a no-op. Arrays within a descriptor retain
their order because schema arrays can carry positional meaning.

## Owners, interfaces and event order

The MCP adapter owns the normalized descriptors, stale-server markers and
notification revision exposed by `McpPort.listTools()` and
`McpPort.toolListRevision()`. Each runtime owns its registered MCP tool names,
last observed revision and complete descriptor signature. The registry and
provider cache are projections of that adapter-owned list. No new owner,
protocol, persistence or cross-module interface is introduced.

```text
server tools/list_changed
  -> adapter marks that server stale and increments revision
  -> next turn: runtime captures revision, then awaits listTools
  -> adapter returns normalized descriptors
  -> runtime compares a stable signature of the complete descriptors
     -> unchanged: record captured revision, preserve registry/cache
     -> changed: replace MCP registrations, invalidate provider cache
```

Refresh stays at the existing turn boundary. An unchanged revision, an
uninitialized runtime or a port without revisions does not trigger a fetch.
A rejected `listTools` leaves the revision unconsumed so the next boundary can
retry. Notifications arriving during the fetch remain observable because the
runtime records the revision captured before the fetch, not a later revision.
Adapter-level retry semantics and server failure handling are unchanged.

Desktop continuous delivery and mobile replayable delivery use the same
runtime registry and turn admission boundary; this change adds no stream,
snapshot, replay, owner/lease or remote attachment behavior. Existing workspace
identity and remote-session routing remain in the original tool registration
and invocation paths. There is no data migration.

## Acceptance

1. With unchanged names/descriptions, independently changing input schema,
   annotations, visibility, timeout or UI metadata replaces the registered
   entry and invalidates the provider cache. Provider contracts and UI/tool
   metadata expose the new values; model/app visibility works in both directions.
2. Complete descriptor changes, including optional fields, update the signature.
   Identical lists, reordered tools and recursively reordered object keys do
   not replace entries or invalidate caches. Ordered schema-array changes do.
3. Unchanged or unavailable revisions and notifications before the next turn
   boundary leave current entries intact. Rejected `McpPort.listTools()` calls
   retry at the next boundary. A new port revision observed during a pending
   `McpPort.listTools()` call triggers another port call at the next boundary;
   this does not guarantee adapter-internal failure retries or stale-marker
   handling.
4. Existing allow/deny filtering, official-CUA authority and plugin ownership
   continue through the existing `registerMcpTools` path.
