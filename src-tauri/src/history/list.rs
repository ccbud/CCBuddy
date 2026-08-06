use serde_json::{json, Value};
use std::path::PathBuf;

use super::codexdedupe::{dedupe_canonical_codex_sessions, limit_with_codex_ancestors};
use super::meta::{meta_cache, session_meta};
use super::paths::{all_dirs, each_session_file, sibling_dir};
use super::TRASH_ID;

pub fn list_sessions(config: &Value, active: &str, limit: usize) -> Vec<Value> {
    // The recycle bin spans every dir and shows only soft-deleted sessions; every other view
    // is scoped to its dir and hides them.
    let trash = active == TRASH_ID;
    // Read (memoized) metas for EVERY candidate, then dedupe/order before the limit cut. Most
    // formats use content-derived CreatedAt so title/tag rewrites cannot reshuffle rows; Codex
    // uses rollout UpdatedAt because its custom metadata is sidecar-only and Codex defines latest
    // that way. The meta cache turns the full walk into stats for unchanged files.
    let mut live: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
    let mut candidates: Vec<(PathBuf, String, String, String)> = Vec::new();
    each_session_file(config, |file, dir_name, id, label| {
        live.insert(file.clone());
        if !trash && active != "all" && id != active {
            return;
        }
        candidates.push((file, dir_name, id.to_string(), label.to_string()));
    });
    // Warm the qoder helper cache in ONE batch before the per-row reads — on a macOS install with
    // protected app data, every stale row would otherwise spawn its own helper process.
    let qoder_files: Vec<PathBuf> = candidates
        .iter()
        .map(|(file, _, _, _)| file.clone())
        .filter(|file| crate::qoder::looks_qoder_path(file))
        .collect();
    crate::qoder::prefetch(&qoder_files);
    let mut out: Vec<Value> = Vec::new();
    for (file, dir_name, id, label) in &candidates {
        if let Some(m) = session_meta(file, dir_name, id, label) {
            out.push(m);
        }
    }
    // Drop memo entries for files that no longer exist, so removed dirs don't pin stale rows.
    if let Ok(mut cache) = meta_cache().lock() {
        cache.retain(|k, _| live.contains(k));
    }
    // Collapse only true physical duplicates (same dir + canonical thread id) BEFORE limit.
    // Threads that merely share rootSessionId are distinct root/subagent nodes and remain intact.
    let mut out = dedupe_canonical_codex_sessions(out);
    // Apply recycle-bin visibility to the selected logical representative, not to each physical
    // candidate. Otherwise deleting the authoritative copy could make a stale duplicate reappear
    // in the normal list while the same logical thread also sits in the recycle bin.
    out.retain(|session| {
        session.get("deleted").and_then(Value::as_bool).unwrap_or(false) == trash
    });
    let key = |v: &Value| {
        // Codex defines "latest" as UpdatedAt (rollout mtime); its title/tags live in a sidecar,
        // so this timestamp is not dirtied by ccbud edits. Keep the stable CreatedAt policy for
        // formats whose transcript itself is rewritten when metadata changes.
        let field = if v.get("source").and_then(Value::as_str) == Some("codex") {
            "lastActivity"
        } else {
            "createdAt"
        };
        v.get(field).and_then(Value::as_f64).unwrap_or(0.0)
    };
    out.sort_by(|a, b| {
        key(b)
            .partial_cmp(&key(a))
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                let updated = |value: &Value| {
                    value.get("lastActivity").and_then(Value::as_f64).unwrap_or(0.0)
                };
                updated(b)
                    .partial_cmp(&updated(a))
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .then_with(|| {
                let a_id = a
                    .get("threadId")
                    .or_else(|| a.get("id"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let b_id = b
                    .get("threadId")
                    .or_else(|| b.get("id"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                b_id.cmp(a_id)
            })
    });
    // Soft-cap Codex trees: include the parent/root chain of every selected child so a busy tree
    // cannot show orphan subagents merely because its older root fell just below the limit.
    limit_with_codex_ancestors(out, limit)
}

pub fn list_projects(config: &Value, active: &str) -> Vec<Value> {
    let sessions = list_sessions(config, active, 600);
    let mut order: Vec<String> = vec![];
    let mut groups: std::collections::HashMap<String, Value> = std::collections::HashMap::new();
    for s in sessions {
        let cwd = s.get("cwd").and_then(|v| v.as_str()).unwrap_or("(unknown)").to_string();
        let la = s.get("lastActivity").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let ct = s.get("createdAt").and_then(|v| v.as_f64()).unwrap_or(la);
        let sk = if s.get("source").and_then(Value::as_str) == Some("codex") { la } else { ct };
        let g = groups.entry(cwd.clone()).or_insert_with(|| {
            order.push(cwd.clone());
            json!({ "cwd": s.get("cwd").cloned().unwrap_or(Value::Null), "name": s.get("project").cloned().unwrap_or(Value::Null), "sessions": [], "lastActivity": 0.0, "createdAt": 0.0, "sortActivity": 0.0 })
        });
        g["sessions"].as_array_mut().unwrap().push(s.clone());
        if la > g["lastActivity"].as_f64().unwrap_or(0.0) {
            g["lastActivity"] = json!(la);
        }
        if ct > g["createdAt"].as_f64().unwrap_or(0.0) {
            g["createdAt"] = json!(ct);
        }
        if sk > g["sortActivity"].as_f64().unwrap_or(0.0) {
            g["sortActivity"] = json!(sk);
        }
    }
    // Codex's latest semantic is rollout UpdatedAt; other formats retain CreatedAt so in-file
    // title/tag edits cannot reorder them. Apply the same source-aware rule to rows and projects.
    let sort_key = |v: &Value| {
        let field = if v.get("source").and_then(Value::as_str) == Some("codex") {
            "lastActivity"
        } else {
            "createdAt"
        };
        v.get(field).and_then(Value::as_f64).unwrap_or(0.0)
    };
    let mut arr: Vec<Value> = order.into_iter().filter_map(|k| groups.remove(&k)).collect();
    for g in &mut arr {
        g["sessions"].as_array_mut().unwrap().sort_by(|a, b| {
            sort_key(b).partial_cmp(&sort_key(a)).unwrap_or(std::cmp::Ordering::Equal)
        });
    }
    arr.sort_by(|a, b| {
        let key = |value: &Value| {
            value.get("sortActivity").and_then(Value::as_f64).unwrap_or(0.0)
        };
        key(b).partial_cmp(&key(a)).unwrap_or(std::cmp::Ordering::Equal)
    });
    for group in &mut arr {
        if let Some(object) = group.as_object_mut() {
            object.remove("sortActivity");
        }
    }
    arr
}

pub fn dir_stats(config: &Value) -> Vec<Value> {
    // Per-dir counts exclude soft-deleted sessions (they're hidden from those views); the deleted
    // ones are tallied separately into the synthetic recycle-bin bucket. Reuse list_sessions so
    // counts reflect canonical logical rows rather than duplicate physical rollout files.
    let mut counts: std::collections::HashMap<String, i64> = std::collections::HashMap::new();
    for session in list_sessions(config, "all", usize::MAX) {
        let id = session.get("dirId").and_then(Value::as_str).unwrap_or("");
        *counts.entry(id.to_string()).or_insert(0) += 1;
    }
    let trash = list_sessions(config, TRASH_ID, usize::MAX).len() as i64;
    let mut out: Vec<Value> = all_dirs(config)
        .into_iter()
        .map(|(id, label, pd)| {
            // A dir "exists" when ANY data tree is on disk — ~/.codex has only sessions/,
            // ~/.copilot only session-state/, ~/.gemini/antigravity-cli only conversations/.
            let exists = pd.is_dir()
                || ["sessions", "session-state", "conversations"]
                    .iter()
                    .any(|n| sibling_dir(&pd, n).map(|s| s.is_dir()).unwrap_or(false));
            let imported = id == "__imported__";
            json!({
                "id": id.clone(), "label": label, "projectsDir": pd.to_string_lossy(),
                "sessions": counts.get(&id).copied().unwrap_or(0), "exists": exists, "imported": imported,
            })
        })
        .collect();
    out.push(json!({
        "id": TRASH_ID, "label": "回收站", "projectsDir": "",
        "sessions": trash, "exists": true, "imported": false, "trash": true,
    }));
    out
}
