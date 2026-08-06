use crate::history::Norm;
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

use super::normalize::normalize;
use super::titles::{first_event_user_title, scan_event_user_title};

// ---- sidecar customization (shared store, ~/.ccbud/codex-meta.json, keyed by rollout stem) ----

fn stem_of(file: &Path) -> String {
    file.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string()
}

/// (custom title, tags, deleted) for a codex session, from the sidecar.
fn sidecar_meta(file: &Path) -> (Option<String>, Vec<String>, bool) {
    crate::sidecar::meta(&crate::sidecar::codex_file(), &stem_of(file))
}

pub fn is_deleted(file: &Path) -> bool {
    sidecar_meta(file).2
}

/// set_ccbud-equivalent for codex sessions: same patch semantics ({title?, tags?, delete?}),
/// persisted to the sidecar instead of the rollout file (never mutate another tool's data).
pub fn set_meta(file: &str, patch: &Value) -> Value {
    let stem = stem_of(Path::new(file));
    if stem.is_empty() {
        return json!({ "ok": false, "reason": "empty" });
    }
    crate::sidecar::set_meta(&crate::sidecar::codex_file(), &stem, patch)
}

/// Drop a session's sidecar entry (after its rollout file is deleted forever).
pub fn remove_meta(file: &str) {
    crate::sidecar::remove_meta(&crate::sidecar::codex_file(), &stem_of(Path::new(file)));
}

// ---- list/detail shapes (codex flavors of history.rs session_meta / get_session) ----

fn subagent_title(n: &Norm) -> String {
    if !n.is_subagent {
        return String::new();
    }
    let path = n
        .agent_path
        .as_deref()
        .unwrap_or("")
        .trim_start_matches('/')
        .strip_prefix("root/")
        .unwrap_or_else(|| n.agent_path.as_deref().unwrap_or("").trim_start_matches('/'));
    let mut parts = Vec::new();
    if let Some(nickname) = n.agent_nickname.as_deref().filter(|value| !value.trim().is_empty()) {
        parts.push(nickname.trim());
    }
    if !path.is_empty() {
        parts.push(path);
    }
    if parts.is_empty() {
        "Codex subagent".to_string()
    } else {
        parts.join(" · ")
    }
}

fn is_canonical_thread_id(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && [8usize, 13, 18, 23].into_iter().all(|index| bytes[index] == b'-')
        && bytes
            .iter()
            .enumerate()
            .all(|(index, byte)| [8usize, 13, 18, 23].contains(&index) || byte.is_ascii_hexdigit())
}

/// List-row meta from already-parsed head records. `dir_id` is `__codex__` for the live tree
/// or `__imported__` for snapshots copied into the app store.
pub fn session_meta_from(file: &Path, recs: &[Value], dir_id: &str, dir_label: &str) -> Option<Value> {
    let meta = fs::metadata(file).ok()?;
    let n = normalize(recs);
    // Live rollouts customize via the sidecar (never rewrite another tool's files); imported
    // COPIES (marked by an .import.json) are our own files, where the standard in-file
    // __ccbud__ (written by set_ccbud) applies.
    let native = crate::history::read_import_meta(&file.to_string_lossy()).is_none();
    let (cc_title, cc_tags, cc_deleted) = if native {
        sidecar_meta(file)
    } else {
        crate::history::read_ccbud(recs)
    };
    let mut transcript_title = crate::history::first_user_text(&n.messages);
    if transcript_title.is_empty() {
        transcript_title = first_event_user_title(recs);
    }
    if transcript_title.is_empty() && meta.len() > 131072 {
        transcript_title = scan_event_user_title(file);
    }
    let agent_title = subagent_title(&n);
    let auto_title = if agent_title.is_empty() { transcript_title } else { agent_title };
    let stem = stem_of(file);
    let mt = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0);
    Some(json!({
        // Row ids are UI identities, so include the configured store. A live rollout and an
        // imported snapshot can legitimately share the same filename/thread id.
        "id": format!("codex:{}:{}", dir_id, stem),
        "file": file.to_string_lossy(),
        "source": "codex",
        "dirId": dir_id,
        "dirLabel": dir_label,
        "sessionId": n.thread_id.clone().or_else(|| n.session_id.clone()).unwrap_or_else(|| stem.clone()),
        "threadId": n.thread_id.clone().or_else(|| n.session_id.clone()).unwrap_or_else(|| stem.clone()),
        "canonicalThreadIdValid": n.thread_id.as_deref().is_some_and(is_canonical_thread_id),
        "rootSessionId": n.session_id.clone().or_else(|| n.thread_id.clone()).unwrap_or_else(|| stem.clone()),
        "parentThreadId": n.parent_thread_id.clone(),
        "forkedFromId": n.forked_from_id.clone(),
        "cwd": n.cwd.clone(),
        "project": n.cwd.as_deref().map(crate::history::base_name).unwrap_or_default(),
        "gitBranch": n.git_branch.clone(),
        "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
        "autoTitle": auto_title,
        "tags": cc_tags,
        "model": n.model,
        "isSubagent": n.is_subagent,
        "agentPath": n.agent_path.clone(),
        "agentNickname": n.agent_nickname.clone(),
        "agentRole": n.agent_role.clone(),
        "agentDepth": n.agent_depth,
        "imported": dir_id == "__imported__",
        "deleted": cc_deleted,
        "createdAt": crate::history::record_created_ms(recs, file),
        "lastActivity": mt,
        "sizeKB": (meta.len() as f64 / 1024.0).round() as i64,
    }))
}

/// Full-detail shape from already-parsed records (history.rs get_session routes here).
pub fn session_from_recs(file: &str, recs: &[Value]) -> Value {
    let path = Path::new(file);
    let n = normalize(recs);
    let import_meta = crate::history::read_import_meta(file);
    // Same sidecar-vs-in-file split as session_meta_from.
    let (cc_title, cc_tags, cc_deleted) = if import_meta.is_none() {
        sidecar_meta(path)
    } else {
        crate::history::read_ccbud(recs)
    };
    let mut transcript_title = crate::history::first_user_text(&n.messages);
    if transcript_title.is_empty() {
        transcript_title = first_event_user_title(recs);
    }
    let agent_title = subagent_title(&n);
    let auto_title = if agent_title.is_empty() { transcript_title } else { agent_title };
    let stem = stem_of(path);
    json!({
        "meta": {
            "id": format!("codex:{}", stem),
            "file": file,
            "source": "codex",
            "assistant": "Codex",
            "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
            "autoTitle": auto_title,
            "tags": cc_tags,
            "summary": Value::Null,
            "sessionId": n.thread_id.clone().or_else(|| n.session_id.clone()).unwrap_or_else(|| stem.clone()),
            "threadId": n.thread_id.clone().or_else(|| n.session_id.clone()).unwrap_or_else(|| stem.clone()),
            "canonicalThreadIdValid": n.thread_id.as_deref().is_some_and(is_canonical_thread_id),
            "rootSessionId": n.session_id.clone().or_else(|| n.thread_id.clone()).unwrap_or_else(|| stem.clone()),
            "parentThreadId": n.parent_thread_id.clone(),
            "forkedFromId": n.forked_from_id.clone(),
            "cwd": n.cwd.clone(),
            "project": n.cwd.as_deref().map(crate::history::base_name).unwrap_or_default(),
            "gitBranch": n.git_branch.clone(),
            "version": n.version.clone(),
            "isSubagent": n.is_subagent,
            "agentPath": n.agent_path.clone(),
            "agentNickname": n.agent_nickname.clone(),
            "agentRole": n.agent_role.clone(),
            "agentDepth": n.agent_depth,
            "deleted": cc_deleted,
            "imported": import_meta.is_some(),
            "importedFrom": import_meta.as_ref().and_then(|m| m.get("originalPath")).cloned().unwrap_or(Value::Null),
            "importedAt": import_meta.as_ref().and_then(|m| m.get("importedAt")).cloned().unwrap_or(Value::Null),
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
