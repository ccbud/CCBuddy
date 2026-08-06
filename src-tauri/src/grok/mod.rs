// Grok Build CLI session support — reads xAI Grok's on-disk sessions
// (`~/.grok/sessions/<percent-encoded-cwd>/<uuid>/chat_history.jsonl`, sibling `summary.json`
// carrying id/cwd/title/model/git/timestamps) and normalizes them into the SAME session/message
// shape the renderer consumes (see history::Norm), so the 对话 view browses Grok sessions
// without renderer forks.
//
// A chat_history line is one of: `system` (harness prompt — skipped), `user` (content blocks of
// text / data-URL image; the human prose is wrapped in <user_query> tags, harness wrappers like
// <user_info>/<git_status> are dropped), `reasoning` ({summary:[{summary_text}]} → thinking),
// `assistant` ({content, tool_calls:[{id,name,arguments-json}]}), and `tool_result`
// ({tool_call_id, content, images?}). Tool names are mapped onto the renderer's native
// vocabulary (both grok tool-name generations: read_file/Read → Read, Shell → Bash, …).
//
// The same uuid dir also holds events/updates/rewind_points/hunk_records .jsonl — only
// chat_history.jsonl is the conversation; walkers must never sweep the rest.
//
// Title/tags/soft-delete live in the shared foreign-CLI sidecar (~/.ccbud/agent-meta.json)
// keyed `grok:<uuid>` — chat_history stems aren't unique, and the files belong to another tool.

#![allow(dead_code)]

mod meta;
mod normalize;
mod roots;
mod session;
#[cfg(test)]
mod tests;

pub use meta::{is_deleted, percent_decode, set_meta};
pub use normalize::normalize;
pub use roots::{grok_label, is_cwd_dir_name, looks_grok_path, root_exists, walk_cwd_dir};
pub use session::{session_from_recs, session_meta_from};
