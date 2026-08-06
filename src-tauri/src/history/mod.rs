// Conversation history.
//
// Reads Claude Code and Codex on-disk sessions across configured dirs, imported snapshots, and
// the app-managed recycle bin. Shapes list/detail payloads for the renderer, including subagents,
// custom title/tags/delete metadata, bundle import/export helpers, and live-watch roots.

#![allow(dead_code)]

mod codexdedupe;
mod edit;
mod foreign;
mod import;
mod importpaths;
mod jsonl;
mod list;
mod meta;
mod norm;
mod paths;
mod search;
mod searchfmt;
mod searchscan;
mod searchtext;
mod selftest;
mod session;
mod skills;
mod subagents;
mod text;

#[cfg(test)]
mod foreign_probe;
#[cfg(test)]
mod tests_foreign;
#[cfg(test)]
mod tests_misc;
#[cfg(test)]
mod tests_qoder;
#[cfg(test)]
mod tests_search;

pub use edit::{delete_session_file, set_ccbud};
pub use importpaths::{import_paths, remove_import};
pub use list::{dir_stats, list_projects, list_sessions};
pub use norm::Norm;
pub use paths::watch_roots;
pub use search::search_sessions;
pub use selftest::{history_selftest, import_selftest};
pub use session::get_session;
pub use subagents::{export_bundle, session_has_subagents, subagent_transcript_paths};

pub(crate) use foreign::{foreign_kind, Foreign};
pub(crate) use jsonl::{
    created_ms, parse_lines, raw_session_bytes, read_head, record_created_ms, session_read_error,
};
pub(crate) use norm::image_block;
pub(crate) use paths::base_name;
pub(crate) use session::read_import_meta;
pub(crate) use skills::{apply_skill_names, skill_from_recs};
pub(crate) use text::{first_user_text, read_ccbud};

/// Synthetic "recycle bin" bucket id. Not a real projects tree (never in all_dirs /
/// each_session_file) — a cross-cutting view of soft-deleted sessions across every dir.
pub const TRASH_ID: &str = "__trash__";
