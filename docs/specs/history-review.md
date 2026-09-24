# CCbuddy history review and calendar timeline

## Product boundary

The new CCbuddy uses the upstream base project as its application and agent foundation.
The only behavior carried forward from the former CCbuddy application is read-only
session review and its cross-session calendar timeline. Provider proxying, CLI
configuration writes, plugin and Skills management, usage monitoring, session
mutation, import, export, and resume actions are outside this feature.

## Ownership and contracts

`@ccbuddy/history` owns discovery, parsing, and the in-memory catalog. Producer
files are the sole authority. The catalog is derived, disposable, and keyed by a
source fingerprint containing canonical path, size, modification time, and inode
where available. A detail request re-reads the source; stale parsed results must
not overwrite a newer fingerprint. The renderer receives typed DTOs through a
read-only desktop boundary. It never receives an arbitrary filesystem read or
write capability.

For SQLite histories, the fingerprint includes the database and any active WAL
or shared-memory siblings. A WAL-only write must change the catalog identity,
and snapshot copying checks the composite identity before publishing results.

The service scans the configured local roots for Claude Code, Codex, Qoder,
Grok Build, GitHub Copilot CLI, and Antigravity CLI. It isolates malformed JSONL
records so one bad row does not hide the remaining session. The source adapter
normalizes messages, tool calls, timing, usage, and child-agent references. Each
record has a stable identity and source order. Missing optional metadata degrades
to an honest unknown value rather than a fabricated fact.

Grok sessions prefer a verified `chat_history.jsonl` when it exists. If that
derived file is missing, discovery selects the sibling `updates.jsonl`, the
producer's durable ACP/xAI event stream, under the same stable session ID. The
fallback reads recognized user, assistant, reasoning, and completed tool events
without writing or rebuilding `chat_history.jsonl`. If the stream contains
rewind or compaction controls that this reader cannot faithfully replay, it
reports a visible read error instead of presenting a misleading transcript.
An unknown event type is diagnosed and skipped; a nonempty stream with no
recognized events is an error. Both Grok files are never listed as two sessions.
Default discovery also includes Codex's `archived_sessions` and Qoder's
`.qoderwork/projects` roots when present.

Refresh reads each JSONL transcript as an asynchronous record stream. The history
owner requests metadata mode for catalog scans: adapters retain only bounded
title text, counts, timestamps, model, parent link, aggregate token usage, and
small per-ID merge state where a producer emits message fragments; they discard
normalized message bodies after each record. Detail mode reopens
the verified source and materializes its messages for the requested session.
Both modes use the same normalization rules and produce the same summary. SQLite
sources use a private verified snapshot and a bounded row cursor, applying the
same metadata/detail split. A cancelled or changing source aborts before its
metadata can be published. Malformed rows remain line-numbered diagnostics.

The calendar consumes only normalized session metadata. It groups first by
project directory or by agent, then uses the opposite dimension as lanes. It
supports week, month, quarter, and year windows; 25% step navigation, drag pan,
today reset, and a bar from creation to last activity. A point session keeps a
minimum six-pixel hit target. Activating a bar opens that session in the reader.
The reader shows user, assistant, reasoning, tool, and subagent content in source
order. Tool payloads and patches retain their original line breaks and diff
markers, with bounded expansion for large output. When normalized token usage is
available, the reader presents the session total and message usage without
inventing zeroes for sources that lack usage data. Search operates on the
currently selected transcript's text, reasoning, and tool payloads. It reports
matching messages, highlights visible matches, and lets keyboard and pointer
users move to the previous or next matching message. Search stays read-only and
does not depend on a cross-session index. Large transcripts use bounded
rendering and preserve keyboard access.
The history view follows the application's current language for Chinese and
English controls and status messages.

Desktop renders session history inside the right-hand main region of the
existing application window. `App` owns the current main-view route; the sidebar,
application menu, and history header request route changes through that one
state owner. Switching between List and Timeline preserves the selected session
and does not create another renderer or window. Leaving history unmounts its
view; returning requests a fresh, read-only catalog refresh. A failed refresh
keeps the last available snapshot visible with an error status.

The desktop sidebar adds a Calendar / Timeline command near its top and a
Sessions command near its bottom, retaining the upstream workbench commands.
Both commands switch the right-hand main region to the requested history view;
they do not open another window. The selected sidebar item and the List/Timeline
switch in the history header share one main-view state. Navigating to a task,
automation, or plugin view restores the existing workbench route. The commands
use the existing dark sidebar surface, spacing, and hover tokens. A non-chat
main view does not highlight a task row as the current navigation item; the
underlying active task remains selected for a later return to chat.

The main renderer receives a versioned, read-only history bridge. Main-process
IPC accepts history list, detail, and refresh requests only from the main frame
of a registered, trusted application window at the expected application entry;
it never grants arbitrary file access. The menu navigates an existing trusted
main window, or creates one when none exists. Menu requests arriving before React
subscribes are replayed once to the main-view owner. A menu request while Settings
covers the workspace returns immediately to the workspace before showing history;
requesting the already selected history view does not trigger the Settings exit
fallback to chat.

## Borrowed design rules

- Codex's protocol-first approach: the read API has an explicit, versioned,
  validated contract. Desktop and UI cross through that contract only.
- Codex's narrow core: each producer parser lives in an adapter; the catalog and
  UI do not contain producer-specific parsing branches.
- Grok Build's authoritative log rule: producer records remain authoritative;
  all indexes and normalized projections are rebuildable.
- Grok Build's stream rule: a refresh emits zero or more progress updates and
  exactly one terminal result. Cancellation or a read error cannot be presented
  as a successful empty library.
- Grok Build's fail-closed boundary: discovery is confined to approved roots,
  rejects symlink escapes, and exposes no mutation command.

Execution safeguards remain outside the read-only history feature. The inherited
agent runtime already implements explicit-deny permission precedence and two-pass
context compaction. Guardian and an OS process sandbox are not implemented here;
adding either requires separate specs and verification.

## Event order and failure semantics

```text
refresh request -> history owner -> approved-root discovery -> per-file parse
                -> progress* -> terminal(success | error | cancelled)
                -> snapshot version -> UI projection
detail request  -> verify catalog identity -> read original producer file
                -> normalize -> return source-stamped detail
```

Each refresh has a monotonically increasing generation. A superseded generation
cannot publish over its replacement. Partial files may still produce a session
with diagnostics. Unreadable roots and failed parsers appear in diagnostics and
do not authorize an empty result as a complete scan. The feature never changes
producer records or config files.

## Acceptance scenarios

1. All six supported producers contribute discoverable sessions and readable
   detail from representative fixtures; bad JSONL rows are isolated.
   A Grok session with only ACP `updates.jsonl` remains visible, shows source
   ordered messages and completed tools, and does not create a chat cache.
   A session with both Grok files appears once. Unsupported replay controls
   surface a read error. Archived Codex and `.qoderwork` records are discovered.
2. A replaced file with the same size and mtime is detected using inode or an
   equivalent source identity; detail is read from the current source.
3. The calendar groups the same sessions by directory and by agent, clips bars
   at the window edges, and can open overlapping and instantaneous sessions.
4. Week, month, quarter, and year navigation and today reset preserve the
   selected range semantics; keyboard users can reach every session.
5. A long transcript remains responsive, and source read failure is visible.
   Refresh memory is bounded by a single JSONL record or SQLite cursor batch,
   rather than the total transcript size, apart from per-session metadata and a
   capped set of malformed-row diagnostics; detail can materialize one transcript.
6. No old CCbuddy gateway, provider, plugin, Skills, usage-monitoring dashboard, import, export,
   resume, or session-editing UI or service is shipped as part of this feature.
7. Searching the selected transcript finds text in messages and tool payloads,
   navigates among matching messages, highlights the selected result, and
   reaches matches beyond the initial render window without mounting the full
   transcript. An empty query clears highlights and an unmatched query reports
   no results.
8. A multiline patch in a tool call remains readable as patch lines, including
   added and removed lines; large tool output expands in bounded steps. Known
   token usage appears as a localized session total and per-message detail;
   missing usage is omitted rather than displayed as zero.
9. The application menu opens the requested List or Timeline view in the right
   main region of a trusted application window, creating a main window if needed.
   No history-only window, HTML entry, or preload is loaded. The same versioned
   read-only bridge works in development and packaged builds; auxiliary windows
   and external frames cannot call its history IPC. From Settings, the menu
   immediately returns to the workspace and keeps the requested history view,
   including when that view was already selected beneath Settings.
10. The desktop sidebar's top calendar command renders Timeline in the right
    main region, and its bottom Sessions command renders List there. The history
    header switches the same route, and the corresponding sidebar item stays
    selected while task rows have no active highlight. No separate window opens
    from these buttons. Selecting a task restores chat and its active row;
    automation and plugin navigation continues to work.
