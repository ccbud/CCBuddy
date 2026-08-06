// Config persistence.
//
// All settings live under ~/.ccbud/config.json (override the dir with CCBUD_HOME, used by
// tests/self-check). Writes are atomic (temp file + rename, mode 0600) so a crash mid-write
// never tears the file. `normalize` keeps the on-disk schema stable across releases.
mod defaults;
mod dirs;
mod io;
mod normalize;
mod paths;
#[cfg(test)]
mod tests;

pub use dirs::{
    ensure_antigravity_dir, ensure_codex_dir, ensure_copilot_dir, ensure_grok_dir,
    ensure_qoder_dir, ensure_xdg_claude_dir,
};
pub use io::{migrate_provider_base_url_to_v1, read_config, write_config};
pub use paths::{ccbud_home, collapse_home, gen_id};
// Part of the module's API but currently only referenced from within it — a non-test build sees
// these re-exports as unused; allow that instead of dropping the paths.
#[allow(unused_imports)]
pub use defaults::default_config;
#[allow(unused_imports)]
pub use normalize::normalize;
