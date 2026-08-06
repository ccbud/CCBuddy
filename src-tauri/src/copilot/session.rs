// Session list rows and the full session payload the renderer's 对话 view consumes.

use super::meta::{session_uuid, sidecar_meta, workspace_yaml};
use super::normalize::normalize;
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

/// List-row meta: workspace.yaml when present (new layout — has copilot's own session name),
/// else the event head (old flat layout).
pub fn session_meta_from(file: &Path, recs: &[Value], dir_id: &str, dir_label: &str) -> Option<Value> {
    let meta = fs::metadata(file).ok()?;
    let ws = workspace_yaml(file);
    let n = normalize(recs);
    let uuid = session_uuid(file);
    let (cc_title, cc_tags, cc_deleted) = sidecar_meta(file);
    let ws_str = |k: &str| {
        ws.as_ref()
            .and_then(|m| m.get(k))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .filter(|s| !s.is_empty())
    };
    let auto_title = ws_str("name").unwrap_or_else(|| crate::history::first_user_text(&n.messages));
    let cwd = ws_str("cwd").or_else(|| n.cwd.clone());
    let created = ws_str("created_at")
        .or_else(|| n.first_ts.clone())
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(&s).ok())
        .map(|d| d.timestamp_millis() as f64)
        .unwrap_or_else(|| crate::history::created_ms(file));
    let mt = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0);
    Some(json!({
        "id": format!("copilot:{}", uuid),
        "file": file.to_string_lossy(),
        "source": "copilot",
        "dirId": dir_id,
        "dirLabel": dir_label,
        "sessionId": n.session_id.clone().unwrap_or_else(|| uuid.clone()),
        "cwd": cwd.clone(),
        "project": cwd.as_deref().map(crate::history::base_name).unwrap_or_default(),
        "gitBranch": ws_str("branch").or_else(|| n.git_branch.clone()).map(Value::from).unwrap_or(Value::Null),
        "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
        "autoTitle": auto_title,
        "tags": cc_tags,
        "model": n.model,
        "isSubagent": false,
        "imported": false,
        "deleted": cc_deleted,
        "createdAt": created,
        "lastActivity": mt,
        "sizeKB": (meta.len() as f64 / 1024.0).round() as i64,
    }))
}

/// Full-detail shape (history.rs get_session routes here).
pub fn session_from_recs(file: &str, recs: &[Value]) -> Value {
    let path = Path::new(file);
    let n = normalize(recs);
    let ws = workspace_yaml(path);
    let (cc_title, cc_tags, cc_deleted) = sidecar_meta(path);
    let ws_name = ws
        .as_ref()
        .and_then(|m| m.get("name"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty());
    let auto_title = ws_name.unwrap_or_else(|| crate::history::first_user_text(&n.messages));
    let uuid = session_uuid(path);
    let cwd = ws
        .as_ref()
        .and_then(|m| m.get("cwd"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .or_else(|| n.cwd.clone());
    json!({
        "meta": {
            "id": format!("copilot:{}", uuid),
            "file": file,
            "source": "copilot",
            "assistant": "Copilot",
            "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
            "autoTitle": auto_title,
            "tags": cc_tags,
            "summary": Value::Null,
            "sessionId": n.session_id.clone().unwrap_or_else(|| uuid.clone()),
            "cwd": cwd.clone(),
            "project": cwd.as_deref().map(crate::history::base_name).unwrap_or_default(),
            "gitBranch": n.git_branch.clone(),
            "version": n.version.clone(),
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
