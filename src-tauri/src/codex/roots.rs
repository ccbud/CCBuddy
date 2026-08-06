// Session roots/paths/walk + rollout format sniffing (split from codex.rs).

use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

/// The DEFAULT config dir as a history-dir entry string (`~/.codex`), used by the one-time
/// startup migration that adds it to `historyDirs`. Honors CODEX_HOME like the codex CLI.
pub fn codex_label() -> String {
    let root = sessions_root();
    let dir = root.parent().unwrap_or(&root);
    crate::store::collapse_home(&dir.to_string_lossy())
}

fn home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}

/// Codex's DEFAULT sessions tree. Honors CODEX_HOME the way the codex CLI does. Only the
/// auto-add migration keys off this — browsing walks `<dir>/sessions` of every configured dir.
pub fn sessions_root() -> PathBuf {
    match std::env::var("CODEX_HOME") {
        Ok(h) if !h.trim().is_empty() => PathBuf::from(h).join("sessions"),
        _ => home().join(".codex").join("sessions"),
    }
}

pub fn root_exists() -> bool {
    sessions_root().is_dir()
}

fn codex_home_for_rollout(file: &Path) -> Option<PathBuf> {
    file.ancestors()
        .find(|dir| {
            matches!(
                dir.file_name().and_then(|name| name.to_str()),
                Some("sessions") | Some("archived_sessions")
            )
        })
        .and_then(Path::parent)
        .map(Path::to_path_buf)
}

fn resolve_sqlite_home_path(raw: &str, codex_home: &Path) -> Option<PathBuf> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    if raw == "~" {
        return Some(home());
    }
    if let Some(rest) = raw.strip_prefix("~/") {
        return Some(home().join(rest));
    }
    let path = PathBuf::from(raw);
    Some(if path.is_absolute() { path } else { codex_home.join(path) })
}

fn configured_sqlite_home(codex_home: &Path) -> Option<PathBuf> {
    let raw = fs::read_to_string(codex_home.join("config.toml")).ok()?;
    let doc = raw.parse::<toml_edit::DocumentMut>().ok()?;
    resolve_sqlite_home_path(doc.get("sqlite_home")?.as_str()?, codex_home)
}

/// Codex treats the completed state DB's rollout_path as authoritative for a canonical thread id.
/// This is intentionally queried only when ccbud has found duplicate physical candidates, so the
/// normal list walk never opens SQLite per row. A missing/stale/incomplete DB simply means callers
/// fall back to validated metadata + mtime, just as Codex does during scan-and-repair.
pub fn preferred_rollout_path(file: &Path, thread_id: &str) -> Option<PathBuf> {
    let codex_home = codex_home_for_rollout(file)?;
    let sqlite_home = configured_sqlite_home(&codex_home)
        .or_else(|| {
            std::env::var("CODEX_SQLITE_HOME")
                .ok()
                .and_then(|value| resolve_sqlite_home_path(&value, &codex_home))
        })
        .unwrap_or(codex_home);
    let db = sqlite_home.join("state_5.sqlite");
    if !db.is_file() {
        return None;
    }
    let conn = Connection::open_with_flags(
        db,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    let status = conn
        .query_row(
            "SELECT status FROM backfill_state WHERE id = 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .ok()??;
    if status != "complete" {
        return None;
    }
    let rollout = conn
        .query_row(
            "SELECT rollout_path FROM threads WHERE id = ?1 AND archived = 0",
            [thread_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .ok()??;
    let rollout = PathBuf::from(rollout);
    rollout.is_file().then_some(rollout)
}

/// Walk every rollout .jsonl under a sessions tree (date-sharded YYYY/MM/DD, but walked
/// generically so a layout change doesn't lose sessions). Depth-capped against cycles.
pub fn walk_sessions<F: FnMut(PathBuf)>(root: &Path, mut cb: F) {
    fn walk<F: FnMut(PathBuf)>(dir: &Path, depth: u32, cb: &mut F) {
        if depth > 6 {
            return;
        }
        let entries = match fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => return,
        };
        for ent in entries.flatten() {
            let p = ent.path();
            if p.is_dir() {
                walk(&p, depth + 1, cb);
            } else if p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("jsonl") {
                cb(p);
            }
        }
    }
    walk(root, 0, &mut cb);
}

/// Format sniff on parsed records — routes files that LOOK like Codex rollouts (incl. copies
/// imported into the app store, where the path no longer says so). Claude Code records never
/// use these type tags, and old-format bare Codex items lack Claude's `.message` wrapper.
pub fn looks_codex(recs: &[Value]) -> bool {
    recs.iter().take(8).any(|r| {
        match r.get("type").and_then(|v| v.as_str()) {
            Some("session_meta") | Some("turn_context") | Some("event_msg") | Some("compacted") => true,
            Some("response_item") => r.get("payload").is_some(),
            // old envelope-less rollout: response items at the top level
            Some("message") | Some("function_call") | Some("function_call_output")
            | Some("reasoning") | Some("local_shell_call") => r.get("message").is_none(),
            _ => r.get("record_type").is_some(),
        }
    })
}
