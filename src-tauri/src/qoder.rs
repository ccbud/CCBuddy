// Qoder CLI session support — Qoder writes Claude Code-FORMAT transcripts into its own trees
// (`~/.qoder/projects/<encoded-cwd>/<uuid>.jsonl` and the same layout under `~/.qoderwork`,
// subagents in `<uuid>/subagents/agent-*.jsonl`), so the normal Claude pipeline in history.rs
// parses them as-is. This module supplies only what differs: root discovery for the auto-add
// migration, path routing (a `.qoder`/`.qoderwork` component followed by `projects/`), the
// `<uuid>-session.json` companion (qoder's own title + working_dir), and the shared foreign-CLI
// sidecar for title/tags/soft-delete — the files belong to another tool and are never rewritten,
// which also means hard-delete refuses them (history.rs).

#![allow(dead_code)]

use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

fn home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}

/// Qoder's two known data roots (both observed in the wild): each is a history-dir entry
/// candidate for the auto-add migration; browsing itself walks every configured dir's
/// `projects/` tree, so these only seed historyDirs.
pub fn default_root() -> PathBuf {
    home().join(".qoder")
}

pub fn work_root() -> PathBuf {
    home().join(".qoderwork")
}

/// A qoder install exists at `root` when its projects tree is on disk.
pub fn root_exists(root: &Path) -> bool {
    root.join("projects").is_dir()
}

/// Container-shape test for routing: a .jsonl anywhere under a `.qoder/projects/` or
/// `.qoderwork/projects/` tree (main sessions AND `<uuid>/subagents/agent-*.jsonl`).
pub fn looks_qoder_path(file: &Path) -> bool {
    if file.extension().and_then(|e| e.to_str()) != Some("jsonl") {
        return false;
    }
    let mut child: Option<&std::ffi::OsStr> = None;
    for anc in file.ancestors().skip(1) {
        let name = match anc.file_name() {
            Some(n) => n,
            None => break,
        };
        if (name == ".qoder" || name == ".qoderwork") && child.map(|c| c == "projects").unwrap_or(false) {
            return true;
        }
        child = Some(name);
    }
    false
}

/// The session uuid (its file stem) — sidecar key and renderer id both build on it.
fn session_stem(file: &Path) -> String {
    file.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string()
}

fn sidecar_key(file: &Path) -> String {
    format!("qoder:{}", session_stem(file))
}

/// (custom title, tags, deleted) from the shared agent sidecar (~/.ccbud/agent-meta.json).
pub fn sidecar_meta(file: &Path) -> (Option<String>, Vec<String>, bool) {
    crate::sidecar::meta(&crate::sidecar::agent_file(), &sidecar_key(file))
}

pub fn is_deleted(file: &Path) -> bool {
    sidecar_meta(file).2
}

pub fn set_meta(file: &str, patch: &Value) -> Value {
    let key = sidecar_key(Path::new(file));
    if key == "qoder:" {
        return json!({ "ok": false, "reason": "empty" });
    }
    crate::sidecar::set_meta(&crate::sidecar::agent_file(), &key, patch)
}

/// Sibling `<uuid>-session.json` companion (qoder's own session metadata:
/// title / working_dir / fork_from / parent_session_id).
fn session_json(file: &Path) -> Option<Value> {
    let stem = session_stem(file);
    if stem.is_empty() {
        return None;
    }
    let p = file.parent()?.join(format!("{}-session.json", stem));
    serde_json::from_str(&fs::read_to_string(p).ok()?).ok()
}

/// Qoder's stored session title (the auto-title fallback beats first-user-text when present).
pub fn session_title(file: &Path) -> Option<String> {
    session_json(file)?
        .get("title")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Companion working_dir — cwd fallback when no record carries one.
pub fn working_dir(file: &Path) -> Option<String> {
    session_json(file)?
        .get("working_dir")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_qoder_paths() {
        assert!(looks_qoder_path(Path::new("/h/.qoder/projects/-Users-a-p/1111-uuid.jsonl")));
        assert!(looks_qoder_path(Path::new("/h/.qoderwork/projects/-Users-a-p/1111-uuid.jsonl")));
        // subagent transcripts under the session's own dir route too (search scans them)
        assert!(looks_qoder_path(Path::new(
            "/h/.qoder/projects/-enc/1111-uuid/subagents/agent-x.jsonl"
        )));
        assert!(!looks_qoder_path(Path::new("/h/.claude/projects/-enc/1111-uuid.jsonl")));
        assert!(!looks_qoder_path(Path::new("/h/.qoder/projects/-enc/1111-uuid-session.json")));
        // projects/ must be DIRECTLY under the qoder root
        assert!(!looks_qoder_path(Path::new("/h/.qoder/sessions/-enc/1111-uuid.jsonl")));
        assert!(!looks_qoder_path(Path::new("/h/qoder/projects/-enc/1111-uuid.jsonl")));
    }

    #[test]
    fn reads_session_json_companion() {
        let dir = std::env::temp_dir().join("ccbud-qoder-companion-test");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let file = dir.join("2222-uuid.jsonl");
        fs::write(&file, "{}\n").unwrap();
        assert_eq!(session_title(&file), None);
        fs::write(
            dir.join("2222-uuid-session.json"),
            "{\"title\":\" Qoder 会话 \",\"working_dir\":\"/tmp/qproj\",\"fork_from\":\"1111\"}",
        )
        .unwrap();
        assert_eq!(session_title(&file).as_deref(), Some("Qoder 会话"));
        assert_eq!(working_dir(&file).as_deref(), Some("/tmp/qproj"));
        let _ = fs::remove_dir_all(&dir);
    }
}
