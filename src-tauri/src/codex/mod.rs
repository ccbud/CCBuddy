// Codex CLI session support — reads OpenAI Codex's on-disk rollout logs
// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) and normalizes them into the SAME
// session/message shape the renderer consumes for Claude Code history, so the 对话 view
// (list / detail / search / live-follow / export) browses both without renderer forks.
//
// A rollout line is `{timestamp, type, payload}` with type ∈ {session_meta, turn_context,
// response_item, event_msg, compacted}. Conversation content lives in response_item payloads
// (message / reasoning / function_call / function_call_output / local_shell_call /
// custom_tool_call / web_search_call); event_msg mostly duplicates that content, but token_count
// carries usage and user_message supplies a bounded title fallback for image-heavy first turns.
// Very old Codex builds wrote
// payload objects directly per line (no envelope) — handled by treating such a line as its
// own payload.
//
// Tool calls are mapped onto the tool vocabulary the renderer already draws natively:
// shell/exec_command/local_shell_call → Bash, update_plan → TodoWrite, view_image → Read,
// web_search → WebSearch, apply_patch → ApplyPatch (a codex-specific card).
//
// Title/tags/soft-delete: Codex files belong to another tool, so per-conversation
// customization never rewrites them (unlike Claude's in-file `__ccbud__`) — it lives in a
// sidecar map at `~/.ccbud/codex-meta.json`, keyed by the rollout file stem.

#![allow(dead_code)]

mod exec;
mod items;
mod meta;
mod normalize;
mod records;
mod roots;
mod titles;
mod tools;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_more;

pub use meta::{is_deleted, remove_meta, session_from_recs, session_meta_from, set_meta};
// normalize/sessions_root are exercised by the #[cfg(test)] modules via these re-exports,
// so a non-test `cargo check` sees them as unused — allow that, don't drop the API.
#[allow(unused_imports)]
pub use normalize::normalize;
pub use records::head_ids;
#[allow(unused_imports)]
pub use roots::{codex_label, looks_codex, preferred_rollout_path, root_exists, sessions_root, walk_sessions};
