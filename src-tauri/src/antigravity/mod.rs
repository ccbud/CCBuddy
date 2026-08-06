// Google Antigravity CLI (`agy`) session support — reads its per-conversation SQLite stores
// (`~/.gemini/antigravity-cli/conversations/<uuid>.db`, `steps` table) plus the sibling
// `conversation_summaries.db` (title / preview / workspace uris — plain text), and normalizes
// them into the SAME session/message shape the renderer consumes (history::Norm).
//
// A step's `step_payload` is a protobuf blob with no published schema. A minimal wire-format
// walker recovers the stable fields (reverse-engineered against real conversations):
//   #1  step type enum        #4 status
//   #5  metadata: #5.1 {sec,nanos} created · #5.4 tool call {#1 id, #2 name, #3 args-JSON,
//       #7 result (opaque/encrypted — not recoverable)} · #5.9 generation stats
//       {#2 input tokens, #3 output tokens}
//   #19 user input: #19.2 text · #19.9 attachments {#1 mime, #2 bytes, #5 path}
//   #20 model turn: #20.1 assistant text
// Steps whose payload drifts from this map degrade to being skipped (never crash) — the
// summaries DB alone still lists the conversation. Tool RESULTS are stored in a non-readable
// encoding, so tool cards show name/args and the renderer's "no result" marker.
//
// DBs may be WAL-journaled and open in a live agy process: connections are read-only with a
// short busy timeout, and freshness checks use max(mtime(db), mtime(db-wal)).
//
// Title/tags/soft-delete live in the shared foreign-CLI sidecar (~/.ccbud/agent-meta.json)
// keyed `antigravity:<uuid>` — the DBs belong to another tool and are never written.

#![allow(dead_code)]
mod content;
mod roots;
mod session;
mod steps;
mod wire;
#[cfg(test)]
mod tests;

pub use roots::{
    agy_label, is_deleted, looks_agy_path, root_exists, set_meta, wal_mtime_ms, walk,
};
// Part of the module's API but currently only referenced from within it — a non-test build sees
// the re-export as unused; allow that instead of dropping the path.
#[allow(unused_imports)]
pub use roots::default_root;
pub use session::{normalize_db, session_from, session_meta_from};
