use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

fn home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}

fn expand_tilde(p: &str) -> PathBuf {
    if let Some(rest) = p.strip_prefix("~/") {
        home().join(rest)
    } else if p == "~" {
        home()
    } else {
        PathBuf::from(p)
    }
}

/// Configured dirs → (id, label, projects_dir). id == the dir string (historyActive matches it).
fn config_dirs(config: &Value) -> Vec<(String, String, PathBuf)> {
    let mut out = vec![];
    if let Some(arr) = config.get("historyDirs").and_then(|v| v.as_array()) {
        for d in arr {
            if let Some(s) = d.as_str() {
                out.push((s.to_string(), s.to_string(), expand_tilde(s).join("projects")));
            }
        }
    }
    out
}

pub(crate) fn base_name(p: &str) -> String {
    p.split('/').filter(|s| !s.is_empty()).last().unwrap_or(p).to_string()
}

/// Best-effort decode of an encoded project dir name → cwd (record cwd wins when present).
pub(super) fn decode_dir_name(name: &str) -> Option<String> {
    if name.is_empty() {
        return None;
    }
    let trimmed = name.trim_start_matches('-');
    Some(format!("/{}", trimmed.replace('-', "/")))
}

pub(super) fn imports_root() -> PathBuf {
    crate::store::ccbud_home().join("imports")
}
/// Configured dirs + the synthetic imported-transcripts store (id `__imported__`).
pub(super) fn all_dirs(config: &Value) -> Vec<(String, String, PathBuf)> {
    let mut dirs = config_dirs(config);
    dirs.push(("__imported__".to_string(), "导入".to_string(), imports_root().join("projects")));
    dirs
}
/// A sibling data tree next to a dir entry's `projects/`. Every configured dir is probed for
/// EVERY layout (Claude Code AND Qoder write `<dir>/projects/…`, Codex and Grok
/// `<dir>/sessions/…`, Copilot `<dir>/session-state/…`, Antigravity `<dir>/conversations/*.db`),
/// so `~/.codex`, `~/.grok`, `~/.copilot`, `~/.gemini/antigravity-cli`, `~/.qoder` are just
/// configured dirs rather than special cases.
pub(super) fn sibling_dir(projects_dir: &Path, name: &str) -> Option<PathBuf> {
    projects_dir.parent().map(|b| b.join(name))
}

fn sessions_dir(projects_dir: &Path) -> Option<PathBuf> {
    sibling_dir(projects_dir, "sessions")
}

/// Dirs to watch for live history changes — each work dir's data trees (all four layouts).
pub fn watch_roots(config: &Value) -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = vec![];
    for (_, _, pd) in all_dirs(config) {
        for name in ["sessions", "session-state", "conversations"] {
            if let Some(sd) = sibling_dir(&pd, name) {
                roots.push(sd);
            }
        }
        roots.push(pd);
    }
    roots
}

/// Walk every session .jsonl across the configured dirs (+ imports), invoking
/// `cb(file, dir_name, dir_id, dir_label)` — both the Claude projects/ tree and the
/// Codex sessions/ tree of each dir.
pub(super) fn each_session_file<F: FnMut(PathBuf, String, &str, &str)>(config: &Value, mut cb: F) {
    for (id, label, root) in all_dirs(config) {
        if let Ok(entries) = fs::read_dir(&root) {
            for ent in entries.flatten() {
                if !ent.path().is_dir() {
                    continue;
                }
                let dir_name = ent.file_name().to_string_lossy().into_owned();
                let pfiles = match fs::read_dir(ent.path()) {
                    Ok(f) => f,
                    Err(_) => continue,
                };
                for f in pfiles.flatten() {
                    let p = f.path();
                    if p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("jsonl") {
                        cb(p, dir_name.clone(), &id, &label);
                    }
                }
            }
        }
        // Codex rollouts live in a date-sharded sessions/ tree; Grok shares the same sessions/
        // root but keys children by percent-encoded cwd (and stuffs sidecar jsonl — events/
        // updates/rewind — beside each chat_history.jsonl), so children are routed one by one
        // rather than letting the codex walker sweep grok trees into garbage rows.
        if let Some(sd) = sessions_dir(&root) {
            if let Ok(children) = fs::read_dir(&sd) {
                for ent in children.flatten() {
                    let p = ent.path();
                    let name = ent.file_name().to_string_lossy().into_owned();
                    if p.is_dir() && crate::grok::is_cwd_dir_name(&name) {
                        crate::grok::walk_cwd_dir(&p, &mut |f| cb(f, String::new(), &id, &label));
                    } else if p.is_dir() {
                        crate::codex::walk_sessions(&p, |f| cb(f, String::new(), &id, &label));
                    } else if p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("jsonl") {
                        cb(p, String::new(), &id, &label);
                    }
                }
            }
        }
        // Copilot session logs (flat <uuid>.jsonl + <uuid>/events.jsonl).
        if let Some(ss) = sibling_dir(&root, "session-state") {
            crate::copilot::walk(&ss, &mut |f| cb(f, String::new(), &id, &label));
        }
        // Antigravity conversations (one SQLite per session).
        if let Some(cd) = sibling_dir(&root, "conversations") {
            crate::antigravity::walk(&cd, &mut |f| cb(f, String::new(), &id, &label));
        }
    }
}
