// GitHub Copilot CLI session support — reads Copilot's on-disk session event logs and
// normalizes them into the SAME session/message shape the renderer consumes (history::Norm).
//
// Two layouts under `~/.copilot/session-state/`:
//   new (≥1.0):  <uuid>/events.jsonl  + sibling workspace.yaml (id/cwd/name/branch/timestamps,
//                flat "key: value" lines — parsed without a YAML dependency)
//   old:         <uuid>.jsonl flat files (same event schema; early builds carry no cwd at all,
//                so those sessions group under the unknown-project bucket)
//
// An event line is `{type, data, id, timestamp, parentId}`. Conversation content:
//   session.start            → cwd/session id/version (data.context.cwd on newer builds)
//   session.model_change     → model (data.newModel)
//   user.message             → user text (data.content)
//   assistant.message        → assistant text + tool_use blocks (data.content,
//                              data.toolRequests[{toolCallId,name,arguments}], data.model)
//   tool.execution_complete  → tool_result (data.toolCallId, data.success, data.result.content)
// Everything else (session.info, system.*, turn markers, tool.execution_start) is harness
// plumbing and skipped — tool arguments already ride the assistant.message request.
//
// Title/tags/soft-delete live in the shared foreign-CLI sidecar (~/.ccbud/agent-meta.json)
// keyed `copilot:<uuid>` — the files belong to another tool and are never rewritten.

#![allow(dead_code)]

mod meta;
mod normalize;
mod roots;
mod session;
#[cfg(test)]
mod tests;

pub use meta::{is_deleted, set_meta};
pub use normalize::normalize;
pub use roots::{copilot_label, looks_copilot_path, root_exists, walk};
pub use session::{session_from_recs, session_meta_from};
