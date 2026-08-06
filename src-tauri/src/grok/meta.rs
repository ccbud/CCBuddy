// Per-session customization (title / tags / soft delete) via the shared foreign-CLI sidecar,
// plus the sibling summary.json that carries id/cwd/title/model/git/timestamps.

use serde_json::{json, Value};
use std::fs;
use std::path::Path;

/// The session uuid (its dir name) — sidecar key and renderer id both build on it.
pub(super) fn session_uuid(file: &Path) -> String {
    file.parent()
        .and_then(|d| d.file_name())
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

pub(super) fn sidecar_key(file: &Path) -> String {
    format!("grok:{}", session_uuid(file))
}

pub(super) fn sidecar_meta(file: &Path) -> (Option<String>, Vec<String>, bool) {
    crate::sidecar::meta(&crate::sidecar::agent_file(), &sidecar_key(file))
}

pub fn is_deleted(file: &Path) -> bool {
    sidecar_meta(file).2
}

pub fn set_meta(file: &str, patch: &Value) -> Value {
    let key = sidecar_key(Path::new(file));
    if key == "grok:" {
        return json!({ "ok": false, "reason": "empty" });
    }
    crate::sidecar::set_meta(&crate::sidecar::agent_file(), &key, patch)
}

/// Sibling summary.json of a chat_history.jsonl (grok's own session metadata).
pub(super) fn summary_of(file: &Path) -> Option<Value> {
    let p = file.parent()?.join("summary.json");
    serde_json::from_str(&fs::read_to_string(p).ok()?).ok()
}

/// Minimal percent-decoding for grok's encoded-cwd dir names (fallback when summary.json
/// is missing; the record cwd wins when present). Also used on Antigravity's file:// uris.
pub fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}
