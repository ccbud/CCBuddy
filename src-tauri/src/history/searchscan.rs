use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

use super::foreign::{cache_stamp_ms, foreign_kind, Foreign};
use super::jsonl::{parse_lines, read_session_text};
use super::norm::shape_messages;
use super::searchtext::{extract_search_text, icount, ifind};
use super::subagents::subagent_dir;

struct SearchCache {
    map: std::collections::HashMap<PathBuf, (f64, u64, std::sync::Arc<String>)>,
    bytes: usize,
}
/// Extracted-text memo, keyed path -> (mtime, size, text). Cleared wholesale past the byte budget
/// (crude but safe — the next search simply re-extracts what it touches).
fn search_cache() -> &'static std::sync::Mutex<SearchCache> {
    static CACHE: std::sync::OnceLock<std::sync::Mutex<SearchCache>> = std::sync::OnceLock::new();
    CACHE.get_or_init(|| std::sync::Mutex::new(SearchCache { map: std::collections::HashMap::new(), bytes: 0 }))
}
const SEARCH_CACHE_BUDGET: usize = 128 * 1024 * 1024;

/// Search one transcript file for `q`: (extracted text, first-match byte offset), or None.
/// Serves from the extraction cache when fresh; otherwise prefilters the raw bytes and only
/// parses candidates — files that can't match are neither parsed nor cached.
fn thread_scan(path: &Path, q: &str, raw_safe: bool) -> Option<(std::sync::Arc<String>, usize)> {
    let meta = fs::metadata(path).ok()?;
    let (mt, sz) = (cache_stamp_ms(path), meta.len());
    if let Ok(cache) = search_cache().lock() {
        if let Some((cmt, csz, text)) = cache.map.get(path) {
            if *cmt == mt && *csz == sz {
                let t = text.clone();
                drop(cache);
                return ifind(&t, q, 0).map(|p| (t, p));
            }
        }
    }
    let fk = foreign_kind(path);
    let messages: Vec<Value> = if fk == Some(Foreign::Antigravity) {
        // SQLite source: no raw-bytes prefilter (the payloads are binary) — extraction is
        // cached, so the decode is paid once per file version.
        crate::antigravity::normalize_db(path).messages
    } else {
        let raw = read_session_text(path).ok()?;
        if raw_safe && ifind(&raw, q, 0).is_none() {
            return None;
        }
        let parsed = parse_lines(&raw);
        let recs = if crate::qoder::looks_qoder_path(path) {
            crate::qoder::normalize_records(&parsed)
        } else {
            parsed
        };
        match fk {
            Some(Foreign::Grok) => crate::grok::normalize(&recs, None).messages,
            Some(Foreign::Copilot) => crate::copilot::normalize(&recs).messages,
            _ => {
                if crate::codex::looks_codex(&recs) {
                    crate::codex::session_from_recs(&path.to_string_lossy(), &recs)
                        .get("messages")
                        .and_then(|v| v.as_array())
                        .cloned()
                        .unwrap_or_default()
                } else {
                    shape_messages(&recs).messages
                }
            }
        }
    };
    let text = std::sync::Arc::new(extract_search_text(&messages));
    if let Ok(mut cache) = search_cache().lock() {
        if cache.bytes + text.len() > SEARCH_CACHE_BUDGET {
            cache.map.clear();
            cache.bytes = 0;
        }
        if let Some((_, _, old)) = cache.map.insert(path.to_path_buf(), (mt, sz, text.clone())) {
            cache.bytes = cache.bytes.saturating_sub(old.len()); // replaced a stale entry
        }
        cache.bytes += text.len();
    }
    ifind(&text, q, 0).map(|p| (text, p))
}

/// Display snippet around the first match: ~56 chars of context either side, whitespace collapsed,
/// ellipsized at cut edges. Slice bounds snap outward/inward to char boundaries.
fn snippet_around(text: &str, pos: usize, match_len: usize) -> String {
    const CTX: usize = 56;
    let mut start = pos.saturating_sub(CTX);
    while start > 0 && !text.is_char_boundary(start) {
        start -= 1;
    }
    let mut end = (pos + match_len + CTX).min(text.len());
    while end < text.len() && !text.is_char_boundary(end) {
        end += 1;
    }
    let body = text[start..end].split_whitespace().collect::<Vec<_>>().join(" ");
    format!("{}{}{}", if start > 0 { "…" } else { "" }, body, if end < text.len() { "…" } else { "" })
}

/// Scan one session — main thread first, then each subagent transcript — and shape the hit the
/// renderer needs to auto-locate: which agent matched, a snippet, and the occurrence count.
pub(super) fn scan_session(file: &Path, q: &str, raw_safe: bool) -> Option<Value> {
    if let Some((text, pos)) = thread_scan(file, q, raw_safe) {
        return Some(json!({
            "file": file.to_string_lossy(),
            "agent": "main",
            "snippet": snippet_around(&text, pos, q.len()),
            "count": icount(&text, q),
        }));
    }
    let dir = subagent_dir(file)?;
    let mut names: Vec<String> = vec![];
    if let Ok(entries) = fs::read_dir(&dir) {
        for ent in entries.flatten() {
            let name = ent.file_name().to_string_lossy().into_owned();
            if name.starts_with("agent-") && name.ends_with(".jsonl") {
                names.push(name);
            }
        }
    }
    names.sort();
    for name in names {
        if let Some((text, pos)) = thread_scan(&dir.join(&name), q, raw_safe) {
            let agent_id = name.trim_start_matches("agent-").trim_end_matches(".jsonl").to_string();
            let meta_path = dir.join(format!("agent-{}.meta.json", agent_id));
            let meta_raw = if crate::qoder::looks_qoder_path(file) {
                crate::qoder::read_text(&meta_path)
            } else {
                fs::read_to_string(&meta_path)
            };
            let meta: Value = meta_raw
                .ok()
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_else(|| json!({}));
            // Key by the spawning tool_use id — the same key read_subagents uses, so the renderer
            // can switch its panel straight to this agent.
            let key = meta
                .get("toolUseId")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| format!("agent:{}", agent_id));
            let agent_type = meta
                .get("agentType")
                .and_then(|v| v.as_str())
                .or_else(|| meta.get("subagent_type").and_then(|v| v.as_str()))
                .unwrap_or("agent");
            return Some(json!({
                "file": file.to_string_lossy(),
                "agent": key,
                "agentType": agent_type,
                "snippet": snippet_around(&text, pos, q.len()),
                "count": icount(&text, q),
            }));
        }
    }
    None
}
