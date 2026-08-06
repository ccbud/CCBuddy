use serde_json::{json, Value};
use std::fs;
use std::path::Path;

use super::foreign::{foreign_kind, Foreign};
use super::jsonl::{parse_lines, read_session_text, session_read_error};
use super::norm::shape_messages;
use super::paths::base_name;
use super::skills::{apply_skill_names, skill_from_recs};
use super::subagents::read_subagents;
use super::text::{first_user_text, read_ccbud};

/// Read the import provenance sidecar (`<stem>.import.json`) for an imported transcript.
pub(crate) fn read_import_meta(file: &str) -> Option<Value> {
    let p = Path::new(file);
    let stem = p.file_stem().and_then(|s| s.to_str())?;
    let dir = p.parent()?;
    let raw = fs::read_to_string(dir.join(format!("{}.import.json", stem))).ok()?;
    serde_json::from_str(&raw).ok()
}

pub fn get_session(file: &str) -> Value {
    let path = Path::new(file);
    let qoder = crate::qoder::looks_qoder_path(path);
    // Foreign sources route by container shape BEFORE the text read — Antigravity sessions are
    // SQLite, and grok/copilot jsonl would otherwise fall through to the Claude shaper.
    match foreign_kind(path) {
        Some(Foreign::Antigravity) => return crate::antigravity::session_from(file),
        Some(fk) => {
            let raw = match read_session_text(path) {
                Ok(s) => s,
                Err(error) => return session_read_error(path, &error),
            };
            let recs = parse_lines(&raw);
            return match fk {
                Foreign::Grok => crate::grok::session_from_recs(file, &recs),
                _ => crate::copilot::session_from_recs(file, &recs),
            };
        }
        None => {}
    }
    let raw = match read_session_text(path) {
        Ok(s) => s,
        Err(error) => return session_read_error(path, &error),
    };
    let parsed_recs = parse_lines(&raw);
    if crate::codex::looks_codex(&parsed_recs) {
        return crate::codex::session_from_recs(file, &parsed_recs);
    }
    let qoder_title = if qoder {
        crate::qoder::session_title_from(&parsed_recs)
    } else {
        None
    };
    let qoder_cwd = if qoder {
        crate::qoder::working_dir_from(&parsed_recs)
    } else {
        None
    };
    let qoder_model = if qoder {
        crate::qoder::model_from(&parsed_recs)
    } else {
        None
    };
    let recs = if qoder {
        crate::qoder::normalize_records(&parsed_recs)
    } else {
        parsed_recs
    };
    let meta_rec = recs
        .iter()
        .find(|r| r.get("cwd").is_some())
        .or_else(|| recs.iter().find(|r| r.get("sessionId").is_some()));
    let agent_rec = recs.iter().find(|r| r.get("agentId").is_some());
    let agent_id = agent_rec
        .and_then(|r| r.get("agentId"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let summary = recs
        .iter()
        .find(|r| r.get("type").and_then(|v| v.as_str()) == Some("summary") && r.get("summary").is_some())
        .and_then(|r| r.get("summary").cloned());
    // Qoder detail mirrors build_session_meta: normalized atomic wrappers, inline metadata, and
    // app-owned title/tags/delete overrides without rewriting another CLI's transcript.
    let (cc_title, cc_tags, cc_deleted) =
        if qoder { crate::qoder::sidecar_meta(path) } else { read_ccbud(&recs) };
    let shaped = shape_messages(&recs);
    let auto_title = qoder_title.unwrap_or_else(|| first_user_text(&shaped.messages));
    let subagent = agent_rec.is_some();
    let top_level_cwd = meta_rec
        .and_then(|r| r.get("cwd"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let cwd = if qoder {
        qoder_cwd.or(top_level_cwd)
    } else {
        top_level_cwd
    };
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
    let base_id = meta_rec
        .and_then(|r| r.get("sessionId"))
        .and_then(|v| v.as_str())
        .unwrap_or(&stem)
        .to_string();
    // A subagent session's id carries the agent suffix; only a top-level session embeds subagents.
    let sess_id = match (subagent, &agent_id) {
        (true, Some(aid)) => format!("{}-{}", base_id, aid),
        _ => base_id.clone(),
    };
    let mut subs = if subagent { serde_json::Map::new() } else { read_subagents(file) };
    apply_skill_names(&shaped.messages, &mut subs);
    // Live Qoder files are never imported snapshots; avoid probing a protected sibling sidecar.
    let import_meta = if qoder { None } else { read_import_meta(file) };

    json!({
        "meta": {
            "id": if qoder { format!("qoder:{}", stem) } else { format!("disk:{}{}", stem, if subagent { ":sub" } else { "" }) },
            "file": file,
            "source": if qoder { "qoder" } else { "disk" },
            // Renderer falls back to Claude when null (the app's home turf carries no label).
            "assistant": if qoder { json!("Qoder") } else { Value::Null },
            "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
            "autoTitle": auto_title,
            "tags": cc_tags,
            "summary": summary,
            "sessionId": sess_id,
            "cwd": cwd.clone(),
            "project": cwd.as_deref().map(base_name).unwrap_or_default(),
            "gitBranch": meta_rec.and_then(|r| r.get("gitBranch")).cloned().unwrap_or(Value::Null),
            "version": meta_rec.and_then(|r| r.get("version")).cloned().unwrap_or(Value::Null),
            "isSubagent": subagent,
            // A standalone subagent transcript self-reports its invoking skill via the sentinel.
            "skill": if subagent { skill_from_recs(&recs) } else { None::<String> },
            "deleted": cc_deleted,
            "imported": import_meta.is_some(),
            "importedFrom": import_meta.as_ref().and_then(|m| m.get("originalPath")).cloned().unwrap_or(Value::Null),
            "importedAt": import_meta.as_ref().and_then(|m| m.get("importedAt")).cloned().unwrap_or(Value::Null),
            "model": qoder_model.or(shaped.model),
            "totals": shaped.totals,
            "messages": shaped.messages.len(),
            "subagentCount": subs.len(),
            "firstTs": shaped.first_ts,
            "lastTs": shaped.last_ts,
        },
        "messages": shaped.messages,
        "subagents": subs,
    })
}
