# Bootstrap interface integration

The existing bootstrap implementation and current contracts remain the source
of truth for application options and workflow read results. The integration
must keep these public interfaces aligned with the upstream v3.15.1 call sites:

- The Host may inject the subagent runtime configuration reader; bootstrap
  passes the Host snapshot to runtime instead of reading a second configuration
  owner. Ordinary CLI use retains startup configuration when the reader is absent.
- Protocol Hosts may inject provider endpoint routing, topic resources and the
  visualize capability flag through `CCbuddyAppOptions`. The protocol entrypoint
  accepts the existing routing port override. These declarations do not create
  new configuration owners or account-backed provider behavior.
- Workflow journal reads return the current `DynamicWorkflowRunEventsResult`
  and `DynamicWorkflowRunArtifactItemsResult` contracts, including `hasMore`.
  Event pages preserve the count and byte limits; artifact item pages preserve
  the field selection and byte limit. The bridge forwards the existing result
  without re-deriving pagination facts.

The application typecheck and actual CLI build are the regression gate for
these declaration-only repairs; they previously failed where implementation
and public interfaces diverged.

## CLI provider and debug integration

The prompt command does not attach the upstream CDN refresh reporter: CCbuddy's
provider entrypoint resolves a local bundled template as required by
`byok-only.md`. The current legacy personal-config import remains attached.
The actual CLI bundle is the regression gate for stale imports of removed
upstream capabilities.

The debug analyzer is the existing read-only aggregation point for SQLite,
event and log observations. Timeline, span, context and cache projections keep
their shared correlation rules in this module for the integration. A scoped
`max-lines` exception documents that aggregation responsibility; other lint
rules and the rest of the debug package remain checked. New independent
analysis responsibilities should use adjacent modules.
