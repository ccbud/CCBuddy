// Qoder CLI session support — Qoder writes Claude-like transcripts into its own trees
// (`~/.qoder/projects/<encoded-cwd>/<uuid>.jsonl` and the same layout under `~/.qoderwork`,
// subagents in `<uuid>/subagents/agent-*.jsonl`). Qoder streams assistant content as atomic
// wrappers and stores title/workspace/runtime metadata inline, so this module provides the small
// normalization layer needed by the normal Claude pipeline, plus root discovery, safe reads,
// path routing, and the shared foreign-CLI sidecar. The source files belong to another tool and
// are never rewritten, which also means hard-delete refuses them (history.rs).

#![allow(dead_code)]
mod guard;
mod limits;
mod meta;
mod normalize;
mod prefetch;
mod read;
mod roots;
mod titles;
#[cfg(target_os = "macos")]
mod exec;
#[cfg(target_os = "macos")]
mod helper;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_more;

pub use meta::{is_deleted, set_meta, sidecar_meta};
pub use roots::{default_root, looks_qoder_path, root_exists, work_root};
pub(crate) use normalize::{looks_qoder_records, normalize_records};
pub(crate) use prefetch::prefetch;
pub(crate) use read::{read_bytes, read_text};
pub(crate) use titles::{model_from, session_title_from, working_dir_from};
