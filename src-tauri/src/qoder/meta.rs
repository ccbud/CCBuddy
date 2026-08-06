// Per-session identity and the shared foreign-CLI sidecar (title / tags / soft-delete). Moved
// verbatim from qoder.rs.

use serde_json::{json, Value};
use std::path::Path;

/// The session uuid (its file stem) — sidecar key and renderer id both build on it.
fn session_stem(file: &Path) -> String {
    file.file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string()
}

fn sidecar_key(file: &Path) -> String {
    format!("qoder:{}", session_stem(file))
}

/// (custom title, tags, deleted) from the shared agent sidecar (~/.ccbud/agent-meta.json).
pub fn sidecar_meta(file: &Path) -> (Option<String>, Vec<String>, bool) {
    crate::sidecar::meta(&crate::sidecar::agent_file(), &sidecar_key(file))
}

pub fn is_deleted(file: &Path) -> bool {
    sidecar_meta(file).2
}

pub fn set_meta(file: &str, patch: &Value) -> Value {
    let key = sidecar_key(Path::new(file));
    if key == "qoder:" {
        return json!({ "ok": false, "reason": "empty" });
    }
    crate::sidecar::set_meta(&crate::sidecar::agent_file(), &key, patch)
}
