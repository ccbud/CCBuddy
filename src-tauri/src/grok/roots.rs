// Where Grok keeps its sessions (`~/.grok/sessions/<percent-encoded-cwd>/<uuid>/`) and how to
// walk them. The uuid dir also holds events/updates/rewind_points/hunk_records .jsonl — only
// chat_history.jsonl is the conversation, so walkers must never sweep the rest.

use std::fs;
use std::path::{Path, PathBuf};

fn home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}

/// Grok's DEFAULT config dir as a history-dir entry string (`~/.grok`). Honors GROK_HOME the way
/// the grok CLI does (summary.json echoes it as `grok_home`). Only the auto-add migration keys
/// off this — browsing walks every configured dir's `sessions/` tree.
pub fn default_root() -> PathBuf {
    match std::env::var("GROK_HOME") {
        Ok(h) if !h.trim().is_empty() => PathBuf::from(h),
        _ => home().join(".grok"),
    }
}

pub fn grok_label() -> String {
    crate::store::collapse_home(&default_root().to_string_lossy())
}

/// A grok install exists when its sessions tree holds at least one percent-encoded cwd dir.
pub fn root_exists() -> bool {
    let sessions = default_root().join("sessions");
    fs::read_dir(&sessions)
        .map(|entries| {
            entries
                .flatten()
                .any(|e| is_cwd_dir_name(&e.file_name().to_string_lossy()) && e.path().is_dir())
        })
        .unwrap_or(false)
}

/// Grok encodes each workspace cwd as a percent-encoded absolute path dir ("%2FUsers%2F…") —
/// the marker that distinguishes a grok sessions/ child from Codex's YYYY date shards.
pub fn is_cwd_dir_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower.starts_with("%2f") || lower.starts_with("%3a%5c") // unix "/", windows "X:\" oddity-proof
}

/// Session files under one encoded-cwd dir: `<dir>/<uuid>/chat_history.jsonl`.
pub fn walk_cwd_dir<F: FnMut(PathBuf)>(dir: &Path, cb: &mut F) {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for ent in entries.flatten() {
        let p = ent.path();
        if !p.is_dir() {
            continue;
        }
        let chat = p.join("chat_history.jsonl");
        if chat.is_file() {
            cb(chat);
        }
    }
}

/// Container-shape test for detail/edit routing: `…/sessions/<enc-cwd>/<uuid>/chat_history.jsonl`.
pub fn looks_grok_path(file: &Path) -> bool {
    if file.file_name().and_then(|n| n.to_str()) != Some("chat_history.jsonl") {
        return false;
    }
    file.parent()
        .and_then(|uuid_dir| uuid_dir.parent())
        .and_then(|enc| enc.file_name())
        .map(|n| is_cwd_dir_name(&n.to_string_lossy()))
        .unwrap_or(false)
}
