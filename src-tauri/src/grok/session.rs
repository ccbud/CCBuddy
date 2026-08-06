// Session list rows and the full session payload the renderer's 对话 view consumes.

use super::meta::{sidecar_meta, session_uuid, summary_of};
use super::meta::percent_decode;
use super::normalize::{normalize, rfc3339_ms};
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

/// List-row meta: summary.json carries everything cheap (title/cwd/model/times); the file head
/// is only parsed when grok didn't store a title yet (fallback to first user prose).
pub fn session_meta_from(file: &Path, dir_id: &str, dir_label: &str) -> Option<Value> {
    let meta = fs::metadata(file).ok()?;
    let sum = summary_of(file);
    let uuid = session_uuid(file);
    let (cc_title, cc_tags, cc_deleted) = sidecar_meta(file);
    let sum_title = sum
        .as_ref()
        .and_then(|s| s.get("generated_title").or_else(|| s.get("session_summary")))
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let auto_title = sum_title.unwrap_or_else(|| {
        let recs = crate::history::parse_lines(&crate::history::read_head(file, 131072));
        let n = normalize(&recs, sum.as_ref());
        crate::history::first_user_text(&n.messages)
    });
    let cwd = sum
        .as_ref()
        .and_then(|s| s.get("info"))
        .and_then(|i| i.get("cwd"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .or_else(|| {
            file.parent()
                .and_then(|d| d.parent())
                .and_then(|enc| enc.file_name())
                .map(|nm| percent_decode(&nm.to_string_lossy()))
        });
    let created = sum
        .as_ref()
        .and_then(|s| s.get("created_at"))
        .and_then(|v| v.as_str())
        .and_then(rfc3339_ms)
        .unwrap_or_else(|| crate::history::created_ms(file));
    let mt = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0);
    Some(json!({
        "id": format!("grok:{}", uuid),
        "file": file.to_string_lossy(),
        "source": "grok",
        "dirId": dir_id,
        "dirLabel": dir_label,
        "sessionId": sum
            .as_ref()
            .and_then(|s| s.get("info"))
            .and_then(|i| i.get("id"))
            .and_then(|v| v.as_str())
            .unwrap_or(&uuid),
        "cwd": cwd.clone(),
        "project": cwd.as_deref().map(crate::history::base_name).unwrap_or_default(),
        "gitBranch": sum.as_ref().and_then(|s| s.get("head_branch")).cloned().unwrap_or(Value::Null),
        "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
        "autoTitle": auto_title,
        "tags": cc_tags,
        "model": sum.as_ref().and_then(|s| s.get("current_model_id")).cloned().unwrap_or(Value::Null),
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
    let sum = summary_of(path);
    let n = normalize(recs, sum.as_ref());
    let (cc_title, cc_tags, cc_deleted) = sidecar_meta(path);
    let sum_title = sum
        .as_ref()
        .and_then(|s| s.get("generated_title").or_else(|| s.get("session_summary")))
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let auto_title = sum_title.unwrap_or_else(|| crate::history::first_user_text(&n.messages));
    let uuid = session_uuid(path);
    json!({
        "meta": {
            "id": format!("grok:{}", uuid),
            "file": file,
            "source": "grok",
            "assistant": "Grok",
            "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
            "autoTitle": auto_title,
            "tags": cc_tags,
            "summary": Value::Null,
            "sessionId": n.session_id.clone().unwrap_or_else(|| uuid.clone()),
            "cwd": n.cwd.clone(),
            "project": n.cwd.as_deref().map(crate::history::base_name).unwrap_or_default(),
            "gitBranch": n.git_branch.clone(),
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
