// Where Copilot keeps its sessions and how to walk them: both on-disk layouts (the newer
// `<uuid>/events.jsonl` directories and the older flat `<uuid>.jsonl` files).

use std::fs;
use std::path::{Path, PathBuf};

fn home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}

/// Copilot's config dir as a history-dir entry string (`~/.copilot`).
pub fn default_root() -> PathBuf {
    home().join(".copilot")
}

pub fn copilot_label() -> String {
    crate::store::collapse_home(&default_root().to_string_lossy())
}

pub fn root_exists() -> bool {
    default_root().join("session-state").is_dir()
}

/// Walk every session log under a `session-state/` tree: flat `<uuid>.jsonl` (old) and
/// `<uuid>/events.jsonl` (new). Dirs without an events.jsonl (created-but-unused sessions,
/// checkpoint-only remnants) hold no conversation and are skipped.
pub fn walk<F: FnMut(PathBuf)>(state_dir: &Path, cb: &mut F) {
    let entries = match fs::read_dir(state_dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for ent in entries.flatten() {
        let p = ent.path();
        if p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            cb(p);
        } else if p.is_dir() {
            let events = p.join("events.jsonl");
            if events.is_file() {
                cb(events);
            }
        }
    }
}

/// Container-shape test for detail/edit routing: a .jsonl directly in `session-state/`, or an
/// `events.jsonl` whose grandparent is `session-state/`.
pub fn looks_copilot_path(file: &Path) -> bool {
    let parent_named = |p: &Path, name: &str| {
        p.file_name().and_then(|n| n.to_str()).map(|n| n == name).unwrap_or(false)
    };
    match file.file_name().and_then(|n| n.to_str()) {
        Some("events.jsonl") => file
            .parent()
            .and_then(|d| d.parent())
            .map(|gp| parent_named(gp, "session-state"))
            .unwrap_or(false),
        Some(n) if n.ends_with(".jsonl") => {
            file.parent().map(|d| parent_named(d, "session-state")).unwrap_or(false)
        }
        _ => false,
    }
}
