use serde_json::{json, Value};
use std::fs;
use std::path::Path;

use super::foreign::foreign_kind;
use super::import::write_imported;
use super::jsonl::read_session_text;
use super::paths::imports_root;
use super::subagents::read_subagent_files;

/// Import a plain .jsonl transcript, bringing along its on-disk subagents dir if present.
/// Foreign-CLI sources (Grok / Copilot / Antigravity) are intentionally not importable —
/// their layouts/formats aren't Claude/Codex, and a Grok chat_history head would otherwise
/// trip looks_codex (its `reasoning` lines look like old envelope-less Codex items).
fn import_one(src: &str) -> i32 {
    let src_path = Path::new(src);
    if foreign_kind(src_path).is_some() {
        return 0;
    }
    let raw = match read_session_text(src_path) {
        Ok(s) => s,
        Err(_) => return 0,
    };
    // Path-less copies of foreign transcripts: refuse anything whose head sniffs as Grok
    // chat_history (type:system + later reasoning/tool_result) or Copilot events
    // (type:session.start with producer copilot-agent).
    let head: Vec<Value> = raw.lines().take(8).filter_map(|l| serde_json::from_str(l.trim()).ok()).collect();
    if looks_foreign_jsonl(&head) {
        return 0;
    }
    let subs = read_subagent_files(src_path);
    let original_name = src_path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    write_imported(&raw, src, original_name, &subs)
}

/// Content sniff for foreign CLI jsonl (used by import when the path no longer carries the
/// original container shape — e.g. a bare chat_history.jsonl dropped into the import dialog).
fn looks_foreign_jsonl(recs: &[Value]) -> bool {
    recs.iter().take(8).any(|r| match r.get("type").and_then(|v| v.as_str()) {
        // Copilot event stream
        Some("session.start") | Some("user.message") | Some("assistant.message")
        | Some("tool.execution_complete") | Some("tool.execution_start") => true,
        // Grok chat_history: top-level system/reasoning/tool_result (Claude wraps these)
        Some("reasoning") | Some("tool_result") if r.get("message").is_none() => true,
        Some("system") if r.get("content").is_some() && r.get("message").is_none() => true,
        _ => false,
    })
}

/// Import a conversation-bundle .zip (main session + `subagents/`), restoring the subagent layout so
/// the pipeline nests them exactly as if they'd been captured live. Round-trips export_bundle.
fn import_zip(src: &str) -> i32 {
    let bytes = match fs::read(src) {
        Ok(b) => b,
        Err(_) => return 0,
    };
    let (main, subs) = crate::ziputil::split_bundle(crate::ziputil::read(&bytes));
    let main_data = match main {
        Some((_, data)) => data,
        None => return 0,
    };
    let raw = match String::from_utf8(main_data) {
        Ok(s) => s,
        Err(_) => return 0,
    };
    let original_name = Path::new(src).file_name().and_then(|n| n.to_str()).unwrap_or("");
    write_imported(&raw, src, original_name, &subs)
}

pub fn import_paths(paths: &[String]) -> Value {
    let (mut imported, mut skipped, mut failed) = (0, 0, 0);
    for src in paths {
        let lower = src.to_lowercase();
        let r = if lower.ends_with(".zip") {
            import_zip(src)
        } else if lower.ends_with(".jsonl") {
            import_one(src)
        } else {
            0
        };
        match r {
            1 => imported += 1,
            2 => skipped += 1,
            _ => failed += 1,
        }
    }
    json!({ "imported": imported, "skipped": skipped, "failed": failed })
}

pub fn remove_import(file: &str) -> Value {
    let root = imports_root();
    let f = Path::new(file);
    // Hard safety: only ever delete inside our own import store.
    if !f.starts_with(&root) {
        return json!({ "ok": false, "error": "outside import store" });
    }
    let dir = f.parent().unwrap_or(Path::new("."));
    let base = f.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let _ = fs::remove_file(f);
    let _ = fs::remove_file(dir.join(format!("{}.import.json", base)));
    let _ = fs::remove_dir_all(dir.join(base)); // subagents/
    json!({ "ok": true })
}
