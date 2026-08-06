// Antigravity data root, path routing, the shared foreign-CLI sidecar, freshness and the
// read-only SQLite connection. Moved verbatim from antigravity.rs.

use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

fn home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}

/// Antigravity CLI's data dir as a history-dir entry string (`~/.gemini/antigravity-cli`).
pub fn default_root() -> PathBuf {
    home().join(".gemini").join("antigravity-cli")
}

pub fn agy_label() -> String {
    crate::store::collapse_home(&default_root().to_string_lossy())
}

pub fn root_exists() -> bool {
    default_root().join("conversations").is_dir()
}

/// Walk every conversation DB under a `conversations/` dir.
pub fn walk<F: FnMut(PathBuf)>(conversations_dir: &Path, cb: &mut F) {
    let entries = match fs::read_dir(conversations_dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for ent in entries.flatten() {
        let p = ent.path();
        if p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("db") {
            cb(p);
        }
    }
}

/// Container-shape test for detail/edit routing: `…/conversations/<uuid>.db`.
pub fn looks_agy_path(file: &Path) -> bool {
    file.extension().and_then(|e| e.to_str()) == Some("db")
        && file
            .parent()
            .and_then(|d| d.file_name())
            .and_then(|n| n.to_str())
            .map(|n| n == "conversations")
            .unwrap_or(false)
}

pub(super) fn session_uuid(file: &Path) -> String {
    file.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string()
}

fn sidecar_key(file: &Path) -> String {
    format!("antigravity:{}", session_uuid(file))
}

pub(super) fn sidecar_meta(file: &Path) -> (Option<String>, Vec<String>, bool) {
    crate::sidecar::meta(&crate::sidecar::agent_file(), &sidecar_key(file))
}

pub fn is_deleted(file: &Path) -> bool {
    sidecar_meta(file).2
}

pub fn set_meta(file: &str, patch: &Value) -> Value {
    let key = sidecar_key(Path::new(file));
    if key == "antigravity:" {
        return json!({ "ok": false, "reason": "empty" });
    }
    crate::sidecar::set_meta(&crate::sidecar::agent_file(), &key, patch)
}

/// WAL-aware freshness stamp: a live agy writes into `<db>-wal` without touching the main
/// file's mtime, so cache keys must take the max of both.
pub fn wal_mtime_ms(file: &Path) -> f64 {
    let m = |p: &Path| {
        fs::metadata(p)
            .and_then(|md| md.modified())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as f64)
            .unwrap_or(0.0)
    };
    let mut wal = file.as_os_str().to_os_string();
    wal.push("-wal");
    m(file).max(m(Path::new(&wal)))
}

pub(super) fn open_ro(path: &Path) -> Option<Connection> {
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    let _ = conn.busy_timeout(std::time::Duration::from_millis(400));
    Some(conn)
}
