// Per-session customization (title / tags / soft delete) via the shared foreign-CLI sidecar,
// plus the sibling workspace.yaml that carries cwd/branch/timestamps for the newer layout.

use serde_json::{json, Value};
use std::fs;
use std::path::Path;

/// The session uuid — the flat file's stem, or the events.jsonl dir name.
pub(super) fn session_uuid(file: &Path) -> String {
    if file.file_name().and_then(|n| n.to_str()) == Some("events.jsonl") {
        file.parent()
            .and_then(|d| d.file_name())
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    } else {
        file.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string()
    }
}

pub(super) fn sidecar_key(file: &Path) -> String {
    format!("copilot:{}", session_uuid(file))
}

pub(super) fn sidecar_meta(file: &Path) -> (Option<String>, Vec<String>, bool) {
    crate::sidecar::meta(&crate::sidecar::agent_file(), &sidecar_key(file))
}

pub fn is_deleted(file: &Path) -> bool {
    sidecar_meta(file).2
}

pub fn set_meta(file: &str, patch: &Value) -> Value {
    let key = sidecar_key(Path::new(file));
    if key == "copilot:" {
        return json!({ "ok": false, "reason": "empty" });
    }
    crate::sidecar::set_meta(&crate::sidecar::agent_file(), &key, patch)
}

/// Sibling workspace.yaml of an events.jsonl, parsed as flat `key: value` lines (the file is
/// machine-written and flat; no YAML dependency needed). None for old flat sessions.
pub(super) fn workspace_yaml(file: &Path) -> Option<serde_json::Map<String, Value>> {
    if file.file_name().and_then(|n| n.to_str()) != Some("events.jsonl") {
        return None;
    }
    let text = fs::read_to_string(file.parent()?.join("workspace.yaml")).ok()?;
    let mut map = serde_json::Map::new();
    for line in text.lines() {
        if let Some((k, v)) = line.split_once(':') {
            let (k, v) = (k.trim(), v.trim());
            if !k.is_empty() && !k.starts_with('#') && !v.is_empty() {
                map.insert(k.to_string(), json!(v.trim_matches('"').trim_matches('\'')));
            }
        }
    }
    Some(map)
}
