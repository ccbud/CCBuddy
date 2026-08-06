use serde_json::{json, Value};
use std::fs;
use std::path::Path;

use super::foreign::{foreign_kind, Foreign};
use super::jsonl::{parse_lines, read_head};
use super::meta::meta_cache;
use super::paths::{all_dirs, sibling_dir};
use super::session::read_import_meta;

/// Write per-conversation customization (custom title + tags) onto the FIRST parseable line as a
/// `__ccbud__` field. Atomic (tmp + rename). Guarded to the configured dirs + the imports store
/// (renderer can't drive an arbitrary-path write, but imported sessions must be titleable/taggable
/// too — mirrors history.js setCcbud, whose getDirs() includes the imported dir).
pub fn set_ccbud(file: &str, patch: &Value, config: &Value) -> Value {
    let target = Path::new(file);
    if !within_scope(target, config) {
        return json!({ "ok": false, "reason": "out-of-scope" });
    }
    // Foreign-CLI sessions are other tools' files (one is SQLite): their title/tags/delete
    // flag always live in the app-owned sidecar. Same cache-drop contract as the codex branch.
    if let Some(fk) = foreign_kind(target) {
        let r = match fk {
            Foreign::Grok => crate::grok::set_meta(file, patch),
            Foreign::Copilot => crate::copilot::set_meta(file, patch),
            Foreign::Antigravity => crate::antigravity::set_meta(file, patch),
        };
        if r.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
            if let Ok(mut cache) = meta_cache().lock() {
                cache.remove(target);
            }
        }
        return r;
    }
    // Qoder sessions are Claude-format but another tool's live files: title/tags/delete go to
    // the shared sidecar (keyed qoder:<uuid>) instead of an in-file rewrite. The sidecar edit
    // doesn't touch the file (no mtime bump), so the list-meta memo is dropped by hand.
    if crate::qoder::looks_qoder_path(target) {
        let r = crate::qoder::set_meta(file, patch);
        if r.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
            if let Ok(mut cache) = meta_cache().lock() {
                cache.remove(target);
            }
        }
        return r;
    }
    let raw = match fs::read_to_string(file) {
        Ok(s) => s,
        Err(_) => return json!({ "ok": false, "reason": "read" }),
    };
    // Live Codex rollouts are another tool's files — their title/tags/delete flag live in the
    // app-owned sidecar instead of being written into the rollout. Imported codex COPIES sit
    // inside our store (marked by .import.json) and take the normal in-file path below.
    let head: Vec<Value> = raw.lines().take(8).filter_map(|l| serde_json::from_str(l.trim()).ok()).collect();
    if crate::codex::looks_codex(&head) && read_import_meta(file).is_none() {
        let r = crate::codex::set_meta(file, patch);
        // A sidecar edit changes the row without touching the rollout file (no mtime bump), so
        // the list-meta memo must be dropped by hand. In-file writes below invalidate via mtime.
        if r.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
            if let Ok(mut cache) = meta_cache().lock() {
                cache.remove(target);
            }
        }
        return r;
    }
    let mut lines: Vec<String> = raw.split('\n').map(|s| s.to_string()).collect();
    let mut found: Option<(usize, Value)> = None;
    for (i, l) in lines.iter().enumerate() {
        let s = l.trim();
        if s.is_empty() {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<Value>(s) {
            if v.is_object() {
                found = Some((i, v));
                break;
            }
        }
    }
    let (idx, mut obj) = match found {
        Some(x) => x,
        None => return json!({ "ok": false, "reason": "empty" }),
    };
    let mut next = obj.get("__ccbud__").and_then(|v| v.as_object()).cloned().unwrap_or_default();
    if let Some(t) = patch.get("title") {
        let t = t.as_str().unwrap_or("").trim().to_string();
        if !t.is_empty() {
            next.insert("title".into(), json!(t));
        } else {
            next.remove("title");
        }
    }
    if let Some(tags) = patch.get("tags") {
        let mut arr: Vec<String> = vec![];
        if let Some(ta) = tags.as_array() {
            for x in ta {
                if let Some(s) = x.as_str() {
                    let s = s.trim();
                    if !s.is_empty() && !arr.iter().any(|y| y == s) {
                        arr.push(s.to_string());
                    }
                }
            }
        }
        if !arr.is_empty() {
            next.insert("tagList".into(), json!(arr));
        } else {
            next.remove("tagList");
        }
    }
    // Soft delete / restore: `delete: true` marks the session deleted; `delete: false` (restore)
    // drops the flag. Restore that empties __ccbud__ removes the field wholesale below.
    if let Some(d) = patch.get("delete") {
        if d.as_bool().unwrap_or(false) {
            next.insert("delete".into(), json!(true));
        } else {
            next.remove("delete");
        }
    }
    let o = obj.as_object_mut().unwrap();
    if !next.is_empty() {
        o.insert("__ccbud__".into(), Value::Object(next));
    } else {
        o.remove("__ccbud__");
    }
    lines[idx] = serde_json::to_string(&obj).unwrap_or_default();
    let out = lines.join("\n");
    let tmp = format!("{}.ccbud.tmp", file);
    if fs::write(&tmp, &out).is_err() {
        return json!({ "ok": false, "reason": "write" });
    }
    if fs::rename(&tmp, file).is_err() {
        let _ = fs::remove_file(&tmp);
        return json!({ "ok": false, "reason": "write" });
    }
    // The rewrite bumps mtime/size, which already invalidates the list-meta memo — dropping the
    // entry outright also covers a same-millisecond, same-length rewrite.
    if let Ok(mut cache) = meta_cache().lock() {
        cache.remove(target);
    }
    json!({ "ok": true })
}

/// Permanently remove a session's .jsonl from disk (recycle-bin "delete forever"). Guarded to the
/// configured dirs + the imports store exactly like set_ccbud, and also drops the session's
/// `<stem>/` subagents tree and any import sidecar (mirrors remove_import's cleanup).
/// Renderer-driven writes/deletes are confined to the configured work dirs' data trees
/// (projects/ AND sessions/) plus the imports store.
fn within_scope(target: &Path, config: &Value) -> bool {
    all_dirs(config).iter().any(|(_, _, pd)| {
        target.starts_with(pd)
            || ["sessions", "session-state", "conversations"]
                .iter()
                .any(|n| sibling_dir(pd, n).map(|sd| target.starts_with(sd)).unwrap_or(false))
    })
}

pub fn delete_session_file(file: &str, config: &Value) -> Value {
    let target = Path::new(file);
    if !within_scope(target, config) {
        return json!({ "ok": false, "reason": "out-of-scope" });
    }
    if !target.is_file() {
        return json!({ "ok": false, "reason": "missing" });
    }
    // A LIVE Codex rollout, Qoder session, or foreign-CLI session is another tool's file — the
    // app only ever soft-deletes those via the sidecar and never rewrites them (see set_ccbud),
    // so "delete forever" must not rm the source either. Imported codex COPIES (marked by an
    // .import.json) are our own snapshots and stay hard-deletable, like Claude sessions the app
    // manages in the configured dirs.
    if foreign_kind(target).is_some() || crate::qoder::looks_qoder_path(target) {
        return json!({ "ok": false, "reason": "foreign" });
    }
    let head = parse_lines(&read_head(target, 131072));
    if crate::codex::looks_codex(&head) && read_import_meta(file).is_none() {
        return json!({ "ok": false, "reason": "foreign" });
    }
    if fs::remove_file(target).is_err() {
        return json!({ "ok": false, "reason": "remove" });
    }
    crate::codex::remove_meta(file); // drop any codex sidecar entry (no-op for Claude sessions)
    let dir = target.parent().unwrap_or(Path::new("."));
    let stem = target.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    if !stem.is_empty() {
        let _ = fs::remove_dir_all(dir.join(stem)); // <stem>/subagents/...
        let _ = fs::remove_file(dir.join(format!("{}.import.json", stem)));
    }
    json!({ "ok": true })
}
