# CCbuddy user data isolation

## Product rule

The new CCbuddy may run alongside the upstream foundation project and the old
CCbuddy under one operating-system account. Its application-owned configuration,
credentials, sessions, logs, device and plugin state, and workflow runs live
under `~/.ccbuddy` by default. Startup and ordinary Agent operations write
application state only below that root, never to a workspace `.ccbuddy`
directory or an upstream product's data root. There is no implicit migration of
old product settings or credentials. External producers' existing session roots
remain read-only inputs to the history viewer.

`~/.ccbuddy/v2` owns desktop settings and services; `~/.ccbuddy/cli` owns CLI
state. Workspace-scoped application state belongs in
`~/.ccbuddy/workspaces/<stable-workspace-key>`, with the original workspace
path still used as the logical scope. If moving a particular project-local
store would change its semantics, block its legacy write until a safe mapping
exists. Explicit Agent edits to a user-selected workspace remain subject to
the normal permission model and are outside this application-state rule.
Renderer localStorage uses `ccbuddy-` prefixes for app preferences and view
state, including theme, locale, code preview, performance mode, MCP state,
command-center search history, and automation tabs. A fresh new-app profile
does not import keys from the upstream product. Desktop telemetry state files and helper
process log labels use CCbuddy names under the same app-owned root.
Workflow drafts, project-scoped saved definitions, and compiled run entry
files all share the workspace-keyed root. Global saved definitions live in
`~/.ccbuddy/workflows`. A project definition still shadows a global definition
of the same name; `project` and `global` describe visibility, not the physical
location of an application-owned file. The workspace key uses
`workspaceIdentity?.trim() || workspacePath` when an identity is available.
Workflow lookup never falls back to a workspace `.ccbuddy/workflows`, and a failed run-entry
write must settle the run as interrupted instead of writing into an OS temp
directory. Draft writes remain best effort and return no draft on failure.
The draft edit permission rule uses the same workspace identity and path
resolver as draft creation. A draft under another identity's state root never
receives the current workspace's automatic edit approval, even when both
workspaces have the same physical path. The first permission decision and the
post-hook input recheck use the same identity.
The bundled provider template is read from the app resource directory, while
its materialized active copy and lock belong under `~/.ccbuddy/v2/provider`.

Explicit `CCBUDDY_*` environment overrides are supported for tests and
operator-controlled deployments; a base-directory override appends `.ccbuddy`.
They do not create a second default data root. A feature must never silently
use an upstream or old-app directory to recover from a missing or unreadable
new CCbuddy directory.
When no explicit credential secret is supplied, Desktop and CLI derive the
same new CCbuddy-specific encryption key. Neither process attempts to decrypt
the upstream project's credential store.

The desktop does not automatically install a Finder Services workflow, because
that would create a file under `~/Library/Services` outside the sole default
data root. Existing Finder Services workflows are left untouched. The desktop
“Clear All Data” action removes the new app's `~/.ccbuddy/v2` settings and
credentials subtree plus its browser storage; its prompt names that exact
directory. Diagnostics may read new CCbuddy logs and selected external producer
logs, but must not silently include upstream private config or credentials. OS
integration files use CCbuddy names; installation and removal leave another
product's files untouched.
The application-generated network CA lives at
`~/.ccbuddy/v2/certs/ccbuddy-network-ca.{pem,key}` and has CCbuddy as its
certificate subject and issuer. An existing complete pair remains stable; a
missing half causes a new pair under those names. Startup does not adopt an
upstream CA or modify its certificate trust entries.

## Owners and event order

`packages/services/src/paths.ts` owns the desktop/services data root. The
desktop bootstrap settings readers and settings service use that same root.
The CLI storage/config adapters own the bundled Agent's user root and agree
with desktop credential paths. Project-scoped runtime stores derive a stable
workspace key from the selected workspace path. No UI component constructs a
data root independently.

```text
OS home / explicit base override -> .ccbuddy -> v2, cli, workspaces/<key>
desktop bootstrap settings -------> same v2 setting.json
Clear All Data request -> confirmation -> ~/.ccbuddy/v2 and browser-data deletion -> relaunch
```

## Acceptance

1. With upstream product data present and no `~/.ccbuddy` tree, new CCbuddy
   starts with its own defaults and leaves the upstream tree byte-for-byte intact.
2. Settings, credentials, sessions, logs, telemetry, workflow state, and
   plugin state resolve below `~/.ccbuddy` by default. Desktop and CLI agree
   on credentials and base-directory override semantics.
3. Startup and routine runtime operations write application state only under
   `~/.ccbuddy`, never to a workspace `.ccbuddy` tree. External history roots remain read-only.
4. Clear All Data removes the named `~/.ccbuddy/v2` subtree and its own browser
   storage, without deleting upstream or external producer data.
5. OS protocol registration uses CCbuddy-owned names and leaves upstream entries
   untouched. Launching the macOS app creates no Finder Services workflow.
6. A fresh CCbuddy network CA has a CCbuddy subject, and its certificate and
   private key exist only in the CCbuddy data tree.
7. Creating, listing, or running a workflow writes no workspace `.ccbuddy`
   directory and no workflow entry under the OS temp directory. With two
   workspace identities sharing a path, their project definitions and drafts
   remain separate; global definitions remain shared.
8. With a shared physical path and two workspace identities, editing a draft
   under the current identity is preapproved, while editing the other draft
   still requires the normal permission decision.
