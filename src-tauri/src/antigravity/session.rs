// Whole-conversation normalization: the summaries DB row, the per-conversation steps DB, and
// the session/meta payloads the renderer consumes. Moved verbatim from antigravity.rs.

use crate::history::Norm;
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

use super::roots::{open_ro, session_uuid, sidecar_meta, wal_mtime_ms};
use super::steps::{find_str_with_prefix, push_step};
use super::wire::{field_msg, field_str, ts_ms_of, wire_fields};

fn uri_to_path(uri: &str) -> String {
    crate::grok::percent_decode(uri.strip_prefix("file://").unwrap_or(uri))
}

/// Workspace cwd for conversations the summaries DB hasn't indexed (a few percent of real
/// stores): the per-conversation trajectory_metadata_blob embeds the workspace file:// uri.
fn fallback_cwd(file: &Path) -> Option<String> {
    let conn = open_ro(file)?;
    let blob: Vec<u8> = conn
        .query_row("SELECT data FROM trajectory_metadata_blob LIMIT 1", [], |r| r.get(0))
        .ok()?;
    find_str_with_prefix(&blob, "file://", 0).map(|u| uri_to_path(&u))
}

/// Title-of-last-resort for un-indexed conversations: the first user step's prose.
fn first_user_step_text(file: &Path) -> Option<String> {
    let conn = open_ro(file)?;
    let payload: Vec<u8> = conn
        .query_row("SELECT step_payload FROM steps WHERE step_type = 14 ORDER BY idx LIMIT 1", [], |r| r.get(0))
        .ok()?;
    let fields = wire_fields(&payload)?;
    let user = field_msg(&fields, 19)?;
    let text = field_str(&user, 2)?;
    let t: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if t.is_empty() {
        None
    } else {
        Some(t.chars().take(90).collect())
    }
}

/// One conversation's summaries-DB row: (title, preview, first workspace path, step_count).
fn summaries_row(file: &Path) -> Option<(String, String, Option<String>, i64)> {
    let root = file.parent()?.parent()?;
    let conn = open_ro(&root.join("conversation_summaries.db"))?;
    let uuid = session_uuid(file);
    conn.query_row(
        "SELECT title, preview, workspace_uris, step_count FROM conversation_summaries WHERE conversation_id = ?1",
        [&uuid],
        |row| {
            let title: String = row.get(0).unwrap_or_default();
            let preview: String = row.get(1).unwrap_or_default();
            let uris: String = row.get(2).unwrap_or_default();
            let steps: i64 = row.get(3).unwrap_or(0);
            Ok((title, preview, uris, steps))
        },
    )
    .ok()
    .map(|(title, preview, uris, steps)| {
        let cwd = serde_json::from_str::<Value>(&uris)
            .ok()
            .and_then(|v| v.as_array().and_then(|a| a.first().cloned()))
            .and_then(|u| u.as_str().map(|s| s.to_string()))
            .map(|u| uri_to_path(&u));
        (title, preview, cwd, steps)
    })
}

/// Read + normalize a conversation DB into the renderer's message model.
pub fn normalize_db(file: &Path) -> Norm {
    let mut n = Norm::default();
    if let Some((_, _, cwd, _)) = summaries_row(file) {
        n.cwd = cwd;
    }
    if n.cwd.is_none() {
        n.cwd = fallback_cwd(file);
    }
    n.session_id = Some(session_uuid(file));
    let conn = match open_ro(file) {
        Some(c) => c,
        None => return n,
    };
    let mut stmt = match conn.prepare("SELECT step_payload FROM steps ORDER BY idx") {
        Ok(s) => s,
        Err(_) => return n,
    };
    let rows = stmt.query_map([], |row| row.get::<_, Vec<u8>>(0));
    if let Ok(rows) = rows {
        for payload in rows.flatten() {
            push_step(&mut n, &payload);
        }
    }
    n.first_ts = n.messages.first().and_then(|m| m.get("ts")).and_then(|v| v.as_str()).map(|s| s.to_string());
    n.last_ts = n.messages.last().and_then(|m| m.get("ts")).and_then(|v| v.as_str()).map(|s| s.to_string());
    n
}

/// Creation stamp (ms) from the first step's timestamp — content-derived, immune to file
/// rewrites, matching record_created_ms semantics for jsonl sources.
fn first_step_ms(file: &Path) -> Option<f64> {
    let conn = open_ro(file)?;
    let payload: Vec<u8> = conn
        .query_row("SELECT step_payload FROM steps ORDER BY idx LIMIT 1", [], |r| r.get(0))
        .ok()?;
    let fields = wire_fields(&payload)?;
    let meta5 = field_msg(&fields, 5)?;
    ts_ms_of(&meta5, 1)
}

/// List-row meta — summaries DB + first-step timestamp; never parses the full step log.
pub fn session_meta_from(file: &Path, dir_id: &str, dir_label: &str) -> Option<Value> {
    let meta = fs::metadata(file).ok()?;
    let uuid = session_uuid(file);
    let (cc_title, cc_tags, cc_deleted) = sidecar_meta(file);
    let sum = summaries_row(file);
    let (sum_title, preview, cwd) = match &sum {
        Some((t, p, c, _)) => (t.trim().to_string(), p.trim().to_string(), c.clone()),
        None => (String::new(), String::new(), None),
    };
    let cwd = cwd.or_else(|| fallback_cwd(file));
    let auto_title: String = if !sum_title.is_empty() {
        sum_title
    } else if !preview.is_empty() {
        preview.chars().take(90).collect()
    } else {
        first_user_step_text(file).unwrap_or_default()
    };
    let created = first_step_ms(file).unwrap_or_else(|| crate::history::created_ms(file));
    Some(json!({
        "id": format!("antigravity:{}", uuid),
        "file": file.to_string_lossy(),
        "source": "antigravity",
        "dirId": dir_id,
        "dirLabel": dir_label,
        "sessionId": uuid,
        "cwd": cwd.clone(),
        "project": cwd.as_deref().map(crate::history::base_name).unwrap_or_default(),
        "gitBranch": Value::Null,
        "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
        "autoTitle": auto_title,
        "tags": cc_tags,
        "model": Value::Null,
        "isSubagent": false,
        "imported": false,
        "deleted": cc_deleted,
        "createdAt": created,
        "lastActivity": wal_mtime_ms(file),
        "sizeKB": (meta.len() as f64 / 1024.0).round() as i64,
    }))
}

/// Full-detail shape (history.rs get_session routes here — the source is SQLite, not jsonl).
pub fn session_from(file: &str) -> Value {
    let path = Path::new(file);
    let n = normalize_db(path);
    let (cc_title, cc_tags, cc_deleted) = sidecar_meta(path);
    let sum = summaries_row(path);
    let sum_title = sum
        .as_ref()
        .map(|(t, _, _, _)| t.trim().to_string())
        .filter(|s| !s.is_empty());
    let auto_title = sum_title.unwrap_or_else(|| crate::history::first_user_text(&n.messages));
    let uuid = session_uuid(path);
    json!({
        "meta": {
            "id": format!("antigravity:{}", uuid),
            "file": file,
            "source": "antigravity",
            "assistant": "Antigravity",
            "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
            "autoTitle": auto_title,
            "tags": cc_tags,
            "summary": Value::Null,
            "sessionId": uuid,
            "cwd": n.cwd.clone(),
            "project": n.cwd.as_deref().map(crate::history::base_name).unwrap_or_default(),
            "gitBranch": Value::Null,
            "version": Value::Null,
            "isSubagent": false,
            "deleted": cc_deleted,
            "imported": false,
            "importedFrom": Value::Null,
            "importedAt": Value::Null,
            "model": n.model,
            "totals": n.totals,
            "messages": n.messages.len(),
            "subagentCount": 0,
            "firstTs": n.first_ts,
            "lastTs": n.last_ts,
        },
        "messages": n.messages,
        "subagents": {},
    })
}
