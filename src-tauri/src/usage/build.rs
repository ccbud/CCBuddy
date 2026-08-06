// Whole-scan aggregation across both trees, plus the cache that keeps the popover's two
// usage_get calls per open off the disk. Moved verbatim from usage.rs.

use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use super::claude::{dedup_claude, parse_claude_line, ClaudeRec};
use super::codex::{codex_files, parse_codex_file, CodexUsage};
use super::model::{bump, collect_jsonl, Day, LossyLines, UsageRec};
use super::roots::active_roots;

// ---------------------------------------------------------------------------
// aggregation
// ---------------------------------------------------------------------------

pub(super) fn build_data(config: &Value, active: &str) -> HashMap<String, Day> {
    let mut days: HashMap<String, Day> = HashMap::new();
    let roots = active_roots(config, active);

    // Claude Code: parse everything, then de-dup globally, then bucket.
    let mut claude_recs: Vec<ClaudeRec> = vec![];
    for root in &roots {
        let mut files = vec![];
        collect_jsonl(&root.join("projects"), 0, &mut files);
        files.sort();
        // Qoder projects/ trees can be macOS-protected: route those files through the guarded
        // reader (helper fallback + cache, warmed in one batch) so 用量 counts the same sessions
        // the 对话 view can browse. Wrapper records that repeat a message id are handled by the
        // usual dedup (max-total wins) and partial snapshots lack output_tokens, so nothing
        // double-counts.
        let qoder_files: Vec<PathBuf> = files
            .iter()
            .filter(|f| crate::qoder::looks_qoder_path(f))
            .cloned()
            .collect();
        crate::qoder::prefetch(&qoder_files);
        for file in files {
            if crate::qoder::looks_qoder_path(&file) {
                let Ok(bytes) = crate::qoder::read_bytes(&file) else { continue };
                for line in String::from_utf8_lossy(&bytes).lines() {
                    if let Some(rec) = parse_claude_line(line.trim()) {
                        claude_recs.push(rec);
                    }
                }
                continue;
            }
            let Some(mut lines) = LossyLines::open(&file) else { continue };
            while let Some(line) = lines.next_line() {
                if let Some(rec) = parse_claude_line(line.trim()) {
                    claude_recs.push(rec);
                }
            }
        }
    }
    for kept in dedup_claude(claude_recs) {
        bump(&mut days, &kept.rec);
    }

    // Codex: per-turn events, de-duped globally by (timestamp, model, tokens) so resumed/forked
    // session copies collapse.
    let mut events: Vec<(CodexUsage, i64, String)> = vec![];
    for root in &roots {
        for file in codex_files(root) {
            parse_codex_file(&file, &mut events);
        }
    }
    let mut seen: HashSet<(i64, String, CodexUsage)> = HashSet::new();
    for (u, ts, model) in events {
        if !seen.insert((ts, model.clone(), u)) {
            continue;
        }
        bump(
            &mut days,
            &UsageRec {
                ts,
                model: Some(model),
                input: (u.input - u.cached).max(0),
                output: u.output,
                cache_read: u.cached,
                cache_creation: 0,
            },
        );
    }
    days
}

// ---- usage cache ----
// build_data scans every history .jsonl (~0.5s cold for ~1200 files), and the popover calls
// usage_get TWICE per open (heatmap "all" + stats range). Cache the scanned per-day map keyed by
// the active dirs, invalidated when history files change (notify watcher) — so the second per-open
// call + repeated opens are instant, and a startup/post-change warm makes the first open instant.
struct UsageCache {
    sig: String,
    days: HashMap<String, Day>,
}
static USAGE_CACHE: std::sync::Mutex<Option<UsageCache>> = std::sync::Mutex::new(None);

fn dirs_sig(config: &Value, active: &str) -> String {
    format!("{}|{:?}", active, active_roots(config, active))
}

pub(super) fn build_data_cached(config: &Value, active: &str) -> HashMap<String, Day> {
    let sig = dirs_sig(config, active);
    {
        // recover a poisoned lock (a panicked scan thread must not disable caching forever)
        let cache = USAGE_CACHE.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(c) = cache.as_ref() {
            if c.sig == sig {
                return c.days.clone();
            }
        }
    }
    let days = build_data(config, active);
    let mut cache = USAGE_CACHE.lock().unwrap_or_else(|p| p.into_inner());
    *cache = Some(UsageCache { sig, days: days.clone() });
    days
}

/// Drop the cached scan — call when history files change so the next read rescans.
pub fn invalidate_cache() {
    let mut cache = USAGE_CACHE.lock().unwrap_or_else(|p| p.into_inner());
    *cache = None;
}

/// Scan + cache now (off the click path). Call at startup and after history changes so the first
/// popover open is instant instead of paying the cold-scan cost.
pub fn warm_cache(config: &Value, active: &str) {
    let _ = build_data_cached(config, active);
}
