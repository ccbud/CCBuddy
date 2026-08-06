use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

use super::foreign::{cache_stamp_ms, foreign_kind, Foreign};
use super::jsonl::{
    mtime_ms, parse_lines, read_head, read_head_result, record_created_ms, session_read_error,
};
use super::norm::line_to_message;
use super::paths::{base_name, decode_dir_name};
use super::text::{first_user_text, read_ccbud};

/// Mtime+size-keyed memo of session_meta list rows (mirrors the JS metaCache). List refreshes
/// fire on every watched write during a live session and previously re-read every candidate's
/// file head each time — with the memo, unchanged sessions cost a stat. Pruned in list_sessions
/// against the live file set; a live Codex rollout's sidecar edit (which does NOT touch the
/// file) is invalidated explicitly by set_ccbud.
pub(super) fn meta_cache() -> &'static std::sync::Mutex<std::collections::HashMap<PathBuf, (f64, u64, Value)>> {
    static CACHE: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<PathBuf, (f64, u64, Value)>>> =
        std::sync::OnceLock::new();
    CACHE.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

pub(super) fn session_meta(file: &Path, dir_name: &str, dir_id: &str, dir_label: &str) -> Option<Value> {
    let (mt, size) = (cache_stamp_ms(file), fs::metadata(file).ok()?.len());
    if let Ok(cache) = meta_cache().lock() {
        if let Some((cmt, csz, v)) = cache.get(file) {
            if *cmt == mt && *csz == size {
                return Some(v.clone());
            }
        }
    }
    let built = build_session_meta(file, dir_name, dir_id, dir_label)?;
    // A permission failure is recoverable without changing the transcript's mtime/size (for
    // example after the user grants macOS App Data access) — never memoize that placeholder row,
    // otherwise it would stay "(conversation)" until the process restarts. Every OTHER read
    // error is memoized like a normal row: the mtime/size key already invalidates it when the
    // file changes, and skipping the memo would re-read a broken transcript on every refresh.
    let awaiting_grant = built
        .get("readError")
        .and_then(|e| e.get("kind"))
        .and_then(|k| k.as_str())
        == Some("permissionDenied");
    if !awaiting_grant {
        if let Ok(mut cache) = meta_cache().lock() {
            cache.insert(file.to_path_buf(), (mt, size, built.clone()));
        }
    }
    Some(built)
}

fn build_session_meta(file: &Path, dir_name: &str, dir_id: &str, dir_label: &str) -> Option<Value> {
    // Foreign sources first — routed by container shape BEFORE any content read (one of them
    // isn't even text), each through its own shaper.
    match foreign_kind(file) {
        Some(Foreign::Grok) => return crate::grok::session_meta_from(file, dir_id, dir_label),
        Some(Foreign::Copilot) => {
            let recs = parse_lines(&read_head(file, 131072));
            return crate::copilot::session_meta_from(file, &recs, dir_id, dir_label);
        }
        Some(Foreign::Antigravity) => return crate::antigravity::session_meta_from(file, dir_id, dir_label),
        None => {}
    }
    let meta = fs::metadata(file).ok()?;
    let size = meta.len();
    let qoder = crate::qoder::looks_qoder_path(file);
    // Qoder stores title/workspace/runtime records throughout the transcript, and its first JSON
    // line can itself exceed the ordinary 128 KiB list window. Read the full file once (the row
    // cache makes this a one-time cost per mtime/size); other formats retain the bounded head.
    let raw = if qoder {
        crate::qoder::read_text(file)
    } else {
        read_head_result(file, 131072)
    };
    let (parsed_recs, read_error) = match raw {
        Ok(raw) => (parse_lines(&raw), Value::Null),
        Err(error) => (
            vec![],
            session_read_error(file, &error)
                .get("error")
                .cloned()
                .unwrap_or(Value::Null),
        ),
    };
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
    // Codex rollouts (a dir's sessions/ tree, or snapshots imported into the app store) list
    // through the codex shaper — the record format shares nothing with Claude's.
    if crate::codex::looks_codex(&recs) {
        return crate::codex::session_meta_from(file, &recs, dir_id, dir_label);
    }
    // Qoder sessions use Claude-like user/assistant envelopes plus inline title/workspace/runtime
    // records and atomic assistant content wrappers. normalize_records makes the message stream
    // Claude-shaped; Qoder-specific metadata remains app-sidecar + inline JSONL data.
    let meta_rec = recs
        .iter()
        .find(|r| r.get("cwd").is_some())
        .or_else(|| recs.iter().find(|r| r.get("sessionId").is_some()));
    let agent_rec = recs.iter().find(|r| r.get("agentId").is_some());
    let msgs: Vec<Value> = recs.iter().filter_map(line_to_message).collect();
    let (cc_title, cc_tags, cc_deleted) =
        if qoder { crate::qoder::sidecar_meta(file) } else { read_ccbud(&recs) };
    let auto_title = qoder_title.unwrap_or_else(|| first_user_text(&msgs));
    let mut model: Option<String> = None;
    for r in &recs {
        if r.get("type").and_then(|v| v.as_str()) == Some("assistant") {
            if let Some(md) = r.get("message").and_then(|m| m.get("model")).and_then(|v| v.as_str()) {
                model = Some(md.to_string());
            }
        }
    }
    if qoder_model.is_some() {
        model = qoder_model;
    }
    let subagent = agent_rec.is_some();
    let top_level_cwd = meta_rec
        .and_then(|r| r.get("cwd"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let cwd = (if qoder {
        qoder_cwd.or(top_level_cwd)
    } else {
        top_level_cwd
    })
    .or_else(|| decode_dir_name(dir_name));
    let stem = file.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
    let mt = mtime_ms(file);
    Some(json!({
        "id": if qoder { format!("qoder:{}", stem) } else { format!("disk:{}{}", stem, if subagent { ":sub" } else { "" }) },
        "file": file.to_string_lossy(),
        "source": if qoder { "qoder" } else { "disk" },
        "dirId": dir_id,
        "dirLabel": dir_label,
        "sessionId": meta_rec.and_then(|r| r.get("sessionId")).and_then(|v| v.as_str()).unwrap_or(&stem),
        "cwd": cwd.clone(),
        "project": cwd.as_deref().map(base_name).unwrap_or_default(),
        "gitBranch": meta_rec.and_then(|r| r.get("gitBranch")).cloned().unwrap_or(Value::Null),
        "title": cc_title.clone().unwrap_or_else(|| auto_title.clone()),
        "autoTitle": auto_title,
        "tags": cc_tags,
        "model": model,
        "isSubagent": subagent,
        "imported": dir_id == "__imported__",
        "deleted": cc_deleted,
        "readError": read_error,
        "createdAt": record_created_ms(&recs, file),
        "lastActivity": mt,
        "sizeKB": (size as f64 / 1024.0).round() as i64,
    }))
}
