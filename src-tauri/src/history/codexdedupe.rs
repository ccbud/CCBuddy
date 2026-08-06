use serde_json::Value;
use std::path::Path;

fn canonical_codex_key(session: &Value) -> Option<String> {
    if session.get("source").and_then(Value::as_str) != Some("codex") {
        return None;
    }
    if session.get("canonicalThreadIdValid").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let thread_id = session.get("threadId").and_then(Value::as_str)?;
    let dir_id = session.get("dirId").and_then(Value::as_str).unwrap_or("");
    Some(format!("{dir_id}\0{thread_id}"))
}

fn codex_canonical_filename(session: &Value) -> bool {
    let Some(thread_id) = session.get("threadId").and_then(Value::as_str) else {
        return false;
    };
    let Some(file) = session.get("file").and_then(Value::as_str) else {
        return false;
    };
    let stem = Path::new(file).file_stem().and_then(|value| value.to_str()).unwrap_or("");
    stem == thread_id || stem.strip_suffix(thread_id).is_some_and(|prefix| prefix.ends_with('-'))
}

fn codex_candidate_preferred(candidate: &Value, current: &Value) -> bool {
    let candidate_file = candidate.get("file").and_then(Value::as_str).unwrap_or("");
    let current_file = current.get("file").and_then(Value::as_str).unwrap_or("");
    let thread_id = candidate
        .get("threadId")
        .and_then(Value::as_str)
        .or_else(|| current.get("threadId").and_then(Value::as_str))
        .unwrap_or("");

    // Codex's completed state DB is authoritative when its rollout_path still exists. Both
    // candidates already passed ccbud's first-SessionMeta parse, so a matching path also verifies
    // that the DB row belongs to this canonical id.
    let preferred_path = [candidate_file, current_file]
        .into_iter()
        .filter(|file| !file.is_empty())
        .find_map(|file| crate::codex::preferred_rollout_path(Path::new(file), thread_id));
    if let Some(preferred) = preferred_path {
        let candidate_matches = Path::new(candidate_file) == preferred.as_path();
        let current_matches = Path::new(current_file) == preferred.as_path();
        if candidate_matches != current_matches {
            return candidate_matches;
        }
    }

    let imported = |value: &Value| value.get("imported").and_then(Value::as_bool).unwrap_or(false);
    if imported(candidate) != imported(current) {
        return !imported(candidate);
    }
    let archived = |file: &str| {
        Path::new(file)
            .components()
            .any(|part| part.as_os_str().to_str() == Some("archived_sessions"))
    };
    if archived(candidate_file) != archived(current_file) {
        return !archived(candidate_file);
    }
    let number = |value: &Value, field: &str| value.get(field).and_then(Value::as_f64).unwrap_or(0.0);
    for field in ["lastActivity", "createdAt"] {
        let candidate_value = number(candidate, field);
        let current_value = number(current, field);
        if candidate_value != current_value {
            return candidate_value > current_value;
        }
    }
    if codex_canonical_filename(candidate) != codex_canonical_filename(current) {
        return codex_canonical_filename(candidate);
    }
    let candidate_size = number(candidate, "sizeKB");
    let current_size = number(current, "sizeKB");
    if candidate_size != current_size {
        return candidate_size > current_size;
    }
    candidate_file > current_file
}

pub(super) fn dedupe_canonical_codex_sessions(sessions: Vec<Value>) -> Vec<Value> {
    let mut out = Vec::with_capacity(sessions.len());
    let mut positions = std::collections::HashMap::<String, usize>::new();
    for session in sessions {
        let Some(key) = canonical_codex_key(&session) else {
            out.push(session);
            continue;
        };
        if let Some(index) = positions.get(&key).copied() {
            if codex_candidate_preferred(&session, &out[index]) {
                out[index] = session;
            }
        } else {
            positions.insert(key, out.len());
            out.push(session);
        }
    }
    out
}

pub(super) fn limit_with_codex_ancestors(sessions: Vec<Value>, limit: usize) -> Vec<Value> {
    if sessions.len() <= limit {
        return sessions;
    }
    let mut positions = std::collections::HashMap::<String, usize>::new();
    for (index, session) in sessions.iter().enumerate() {
        if let Some(key) = canonical_codex_key(session) {
            positions.insert(key, index);
        }
    }
    let mut included: std::collections::HashSet<usize> = (0..limit).collect();
    let mut queue: Vec<usize> = (0..limit).collect();
    let mut cursor = 0usize;
    while cursor < queue.len() {
        let index = queue[cursor];
        cursor += 1;
        let session = &sessions[index];
        if canonical_codex_key(session).is_none() {
            continue;
        }
        let dir_id = session.get("dirId").and_then(Value::as_str).unwrap_or("");
        let direct_parent = session.get("parentThreadId").and_then(Value::as_str);
        let root_parent = session
            .get("isSubagent")
            .and_then(Value::as_bool)
            .unwrap_or(false)
            .then(|| session.get("rootSessionId").and_then(Value::as_str))
            .flatten();
        let parent_index = [direct_parent, root_parent]
            .into_iter()
            .flatten()
            .find_map(|parent_id| positions.get(&format!("{dir_id}\0{parent_id}")).copied());
        let Some(parent_index) = parent_index else {
            continue;
        };
        if included.insert(parent_index) {
            queue.push(parent_index);
        }
    }
    sessions
        .into_iter()
        .enumerate()
        .filter_map(|(index, session)| included.contains(&index).then_some(session))
        .collect()
}
