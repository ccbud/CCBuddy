// ---- import (copy someone else's .jsonl into the app-managed store) ----

use serde_json::{json, Value};
use std::fs;
use std::path::Path;

use super::jsonl::parse_lines;
use super::paths::imports_root;

fn encode_cwd(cwd: Option<&str>) -> String {
    match cwd {
        Some(c) if !c.is_empty() => c.replace(['/', '\\'], "-"),
        _ => "-imported".to_string(),
    }
}

fn copy_dir(src: &Path, dst: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dst)?;
    for e in fs::read_dir(src)? {
        let e = e?;
        let s = e.path();
        let d = dst.join(e.file_name());
        if s.is_dir() {
            copy_dir(&s, &d)?;
        } else {
            fs::copy(&s, &d)?;
        }
    }
    Ok(())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn records_to_jsonl(records: &[Value]) -> String {
    let mut text = records
        .iter()
        .map(|r| serde_json::to_string(r).unwrap_or_default())
        .collect::<Vec<_>>()
        .join("\n");
    text.push('\n');
    text
}

/// A qoder transcript imported into the app store loses its container path and would otherwise
/// re-parse as raw Claude records: queued commands vanish, redacted duplicates render, atomic
/// wrappers stay fragmented, and qoder's own title is lost. Sniffed by CONTENT (import copies and
/// bundle zips carry no .qoder path), the copy is rewritten up front — normalized records, with
/// the qoder title carried onto the first line's __ccbud__ so the import keeps its name.
pub(super) fn qoder_import_raw(recs: &[Value]) -> Option<(String, Vec<Value>)> {
    if !crate::qoder::looks_qoder_records(recs) {
        return None;
    }
    let mut normalized = crate::qoder::normalize_records(recs);
    if let Some(title) = crate::qoder::session_title_from(recs) {
        if let Some(first) = normalized.iter_mut().find(|r| r.is_object()) {
            let obj = first.as_object_mut().unwrap();
            let mut cc = obj.get("__ccbud__").and_then(|v| v.as_object()).cloned().unwrap_or_default();
            cc.entry("title".to_string()).or_insert_with(|| json!(title));
            obj.insert("__ccbud__".into(), Value::Object(cc));
        }
    }
    Some((records_to_jsonl(&normalized), normalized))
}

/// Snapshot a transcript (already read into `raw`) plus its subagent sidecars into the import store,
/// laid out like a native projects/ tree + a provenance sidecar. `subagents`: (filename, bytes) to
/// drop under `<baseId>/subagents/` — names are basename-reduced and pattern-checked so a crafted
/// entry can't escape the directory. Returns 1 = imported, 2 = skipped (already present),
/// 0 = failed/not-a-transcript. Shared by the plain-.jsonl and .zip-bundle import paths.
pub(super) fn write_imported(raw: &str, original_path: &str, original_name: &str, subagents: &[(String, Vec<u8>)]) -> i32 {
    let recs = parse_lines(raw);
    let is_codex = crate::codex::looks_codex(&recs);
    // Qoder content is rewritten to Claude shape before storing — the has_msg gate below then
    // sees the materialized queued-command user turns too.
    let (qoder_text, recs) = match qoder_import_raw(&recs) {
        Some((text, normalized)) => (Some(text), normalized),
        None => (None, recs),
    };
    let raw = qoder_text.as_deref().unwrap_or(raw);
    let has_msg = recs.iter().any(|r| {
        let t = r.get("type").and_then(|v| v.as_str());
        (t == Some("user") || t == Some("assistant")) && r.get("message").is_some()
    });
    if !has_msg && !is_codex {
        return 0;
    }
    let name_stem = || Path::new(original_name).file_stem().and_then(|s| s.to_str()).unwrap_or("import").to_string();
    // Codex rollouts keep cwd/session id inside the session_meta payload, not on the records.
    let (cwd_owned, base_id) = if is_codex {
        let (c, s) = crate::codex::head_ids(&recs);
        (c, s.unwrap_or_else(name_stem))
    } else {
        let meta_rec = recs.iter().find(|r| r.get("cwd").is_some()).or_else(|| recs.iter().find(|r| r.get("sessionId").is_some()));
        (
            meta_rec.and_then(|r| r.get("cwd")).and_then(|v| v.as_str()).map(|s| s.to_string()),
            meta_rec
                .and_then(|r| r.get("sessionId"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(name_stem),
        )
    };
    let cwd = cwd_owned.as_deref();
    let dest_dir = imports_root().join("projects").join(encode_cwd(cwd));
    let dest_file = dest_dir.join(format!("{}.jsonl", base_id));
    if dest_file.exists() {
        return 2;
    }
    if fs::create_dir_all(&dest_dir).is_err() || fs::write(&dest_file, raw).is_err() {
        return 0;
    }
    if !subagents.is_empty() {
        let sub_dir = dest_dir.join(&base_id).join("subagents");
        if fs::create_dir_all(&sub_dir).is_ok() {
            for (name, bytes) in subagents {
                // file_name() strips any directory component, so the write can't escape sub_dir.
                let safe = Path::new(name).file_name().and_then(|n| n.to_str()).unwrap_or("");
                let lower = safe.to_lowercase();
                if lower.starts_with("agent-") && (lower.ends_with(".jsonl") || lower.ends_with(".meta.json")) {
                    // A qoder session's subagent transcripts carry the same atomic wrappers —
                    // the parent's sniff decides, so the whole stored copy is Claude-shaped.
                    if qoder_text.is_some() && lower.ends_with(".jsonl") {
                        if let Ok(text) = std::str::from_utf8(bytes) {
                            let normalized = crate::qoder::normalize_records(&parse_lines(text));
                            let _ = fs::write(sub_dir.join(safe), records_to_jsonl(&normalized));
                            continue;
                        }
                    }
                    let _ = fs::write(sub_dir.join(safe), bytes);
                }
            }
        }
    }
    let sidecar = dest_dir.join(format!("{}.import.json", base_id));
    let _ = fs::write(
        &sidecar,
        serde_json::to_vec_pretty(&json!({
            "originalPath": original_path,
            "originalName": original_name,
            "sessionId": base_id,
            "importedAt": now_ms(),
        }))
        .unwrap_or_default(),
    );
    1
}
