use serde_json::Value;
use std::path::PathBuf;

use super::foreign::is_session_deleted;
use super::jsonl::created_ms;
use super::list::list_sessions;
use super::searchscan::scan_session;
use super::TRASH_ID;

/// Content search over the same candidate set (and dir/trash scoping) as the list view, newest
/// first. Returns [{ file, agent, agentType?, snippet, count }] for up to `limit` sessions.
pub fn search_sessions(config: &Value, active: &str, query: &str, limit: usize) -> Vec<Value> {
    let q = query.trim();
    if q.is_empty() {
        return vec![];
    }
    let trash = active == TRASH_ID;
    // The raw-bytes prefilter only applies to queries whose every byte is guaranteed to appear
    // verbatim in the file's JSON encoding: printable ASCII minus the chars JSON escapes
    // (quote/backslash/control). Non-ASCII stays OFF the prefilter — some producers (e.g.
    // Python's json.dumps default) escape it as \uXXXX, which a byte scan would miss; those
    // queries always take the parse+extract path (cached, so paid once per file version).
    let raw_safe = q.bytes().all(|b| b.is_ascii() && b != b'"' && b != b'\\' && b >= 0x20);
    // Reuse the list's pre-limit canonical-thread dedupe, directory/trash scope, and ordering.
    // Otherwise duplicate physical rollouts could consume the 600-file search window even though
    // the sidebar shows only their selected representative.
    let files: Vec<(PathBuf, f64)> = list_sessions(config, active, 600)
        .into_iter()
        .filter_map(|session| {
            let file = PathBuf::from(session.get("file")?.as_str()?);
            let created = session
                .get("createdAt")
                .and_then(Value::as_f64)
                .unwrap_or_else(|| created_ms(&file));
            Some((file, created))
        })
        .collect();
    // One batch helper call instead of a spawn per protected qoder file inside the worker loop
    // (repeat scans of unchanged files are then served by the extraction + helper caches).
    let qoder_files: Vec<PathBuf> = files
        .iter()
        .map(|(file, _)| file.clone())
        .filter(|file| crate::qoder::looks_qoder_path(file))
        .collect();
    crate::qoder::prefetch(&qoder_files);
    let hits = std::sync::Mutex::new(Vec::<(f64, Value)>::new());
    let next = std::sync::atomic::AtomicUsize::new(0);
    let workers = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(1, 8);
    std::thread::scope(|s| {
        for _ in 0..workers {
            s.spawn(|| loop {
                let i = next.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                if i >= files.len() {
                    break;
                }
                let (file, ct) = &files[i];
                if is_session_deleted(file) != trash {
                    continue;
                }
                if let Some(hit) = scan_session(file, q, raw_safe) {
                    if let Ok(mut h) = hits.lock() {
                        h.push((*ct, hit));
                    }
                }
            });
        }
    });
    let mut hits = hits.into_inner().unwrap_or_else(|e| e.into_inner());
    hits.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    hits.truncate(limit);
    hits.into_iter().map(|(_, v)| v).collect()
}
