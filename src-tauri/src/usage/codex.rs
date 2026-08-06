// Codex (sessions/ + archived_sessions/ trees) rollout parsing. Moved verbatim from usage.rs.

use serde_json::Value;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

use super::model::{collect_jsonl, LossyLines};
use super::roots::parse_ts;

// ---------------------------------------------------------------------------
// Codex (sessions/ + archived_sessions/ trees)
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Default, PartialEq, Eq, Hash)]
pub(super) struct CodexUsage {
    pub(super) input: i64,
    pub(super) cached: i64,
    pub(super) output: i64,
    pub(super) reasoning: i64,
    total: i64,
}

/// Lenient token-usage decode (ccusage accepts several field aliases per component).
fn codex_usage_of(v: &Value) -> Option<CodexUsage> {
    let o = v.as_object()?;
    let g = |keys: &[&str]| keys.iter().find_map(|k| o.get(*k).and_then(|v| v.as_i64())).unwrap_or(0);
    let input = g(&["input_tokens", "prompt_tokens", "input"]);
    let cached = g(&["cached_input_tokens", "cache_read_input_tokens", "cached_tokens"]);
    let output = g(&["output_tokens", "completion_tokens", "output"]);
    let reasoning = g(&["reasoning_output_tokens", "reasoning_tokens"]);
    let total = match o.get("total_tokens").and_then(|v| v.as_i64()) {
        Some(t) if t > 0 || input + output + reasoning == 0 => t,
        _ => input + output + reasoning,
    };
    Some(CodexUsage { input, cached, output, reasoning, total })
}

fn codex_usage_sub(cur: CodexUsage, prev: Option<CodexUsage>) -> CodexUsage {
    let p = prev.unwrap_or_default();
    CodexUsage {
        input: (cur.input - p.input).max(0),
        cached: (cur.cached - p.cached).max(0),
        output: (cur.output - p.output).max(0),
        reasoning: (cur.reasoning - p.reasoning).max(0),
        total: (cur.total - p.total).max(0),
    }
}

fn codex_model_of(v: Option<&Value>) -> Option<String> {
    let o = v?.as_object()?;
    o.get("model")
        .or_else(|| o.get("model_name"))
        .or_else(|| o.get("metadata").and_then(|m| m.get("model")))
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(String::from)
}

/// Whether this rollout is a `thread_spawn` subagent session (marker in the file head).
fn codex_is_subagent(file: &Path) -> bool {
    use std::io::Read;
    let Ok(mut f) = std::fs::File::open(file) else { return false };
    let mut buf = [0u8; 16 * 1024];
    let n = f.read(&mut buf).unwrap_or(0);
    buf[..n].windows(b"thread_spawn".len()).any(|w| w == b"thread_spawn")
}

/// A subagent file replays the parent's token_count history as a leading burst that shares one
/// timestamp-second — detect that second (the first two usage events landing on the same second),
/// so the replay can be skipped while the cumulative baseline still advances.
fn codex_replay_second(file: &Path) -> Option<String> {
    let mut first: Option<String> = None;
    let mut lines = LossyLines::open(file)?;
    while let Some(line) = lines.next_line() {
        let Some((ts, payload)) = codex_token_count_line(&line) else { continue };
        let info = payload.get("info");
        let has_usage = info
            .map(|i| i.get("last_token_usage").is_some() || i.get("total_token_usage").is_some())
            .unwrap_or(false);
        if !has_usage {
            continue;
        }
        let second: String = ts.chars().take(19).collect();
        match &first {
            None => first = Some(second),
            Some(f) => return if *f == second { Some(second) } else { None },
        }
    }
    None
}

/// Parse a line as a `token_count` event → (timestamp, payload). None for everything else.
fn codex_token_count_line(line: &str) -> Option<(String, Value)> {
    if !line.contains("token_count") {
        return None;
    }
    let r: Value = serde_json::from_str(line).ok()?;
    if r.get("type").and_then(|v| v.as_str()) != Some("event_msg") {
        return None;
    }
    let p = r.get("payload")?;
    if p.get("type").and_then(|v| v.as_str()) != Some("token_count") {
        return None;
    }
    let ts = r.get("timestamp").and_then(|v| v.as_str())?.to_string();
    Some((ts, p.clone()))
}

/// Parse one Codex rollout file into per-turn usage events (ccusage semantics — see module doc).
pub(super) fn parse_codex_file(file: &Path, out: &mut Vec<(CodexUsage, i64, String)>) {
    let replay_second = if codex_is_subagent(file) { codex_replay_second(file) } else { None };
    let mut skip_replay = replay_second.is_some();
    let mut current_model: Option<String> = None;
    let mut prev_totals: Option<CodexUsage> = None;
    let Some(mut lines) = LossyLines::open(file) else { return };
    while let Some(line) = lines.next_line() {
        let s = line.trim();
        if s.is_empty() {
            continue;
        }
        // turn_context carries the active model
        if s.contains("turn_context") {
            if let Ok(r) = serde_json::from_str::<Value>(s) {
                if r.get("type").and_then(|v| v.as_str()) == Some("turn_context") {
                    if let Some(m) = codex_model_of(r.get("payload")) {
                        current_model = Some(m);
                    }
                    continue;
                }
            }
        }
        let Some((ts_str, payload)) = codex_token_count_line(s) else { continue };
        let info = payload.get("info").filter(|i| !i.is_null());
        let total = info.and_then(|i| i.get("total_token_usage")).and_then(codex_usage_of);
        let last = info.and_then(|i| i.get("last_token_usage")).and_then(codex_usage_of);
        // leading parent-history replay in a subagent file: skip, but keep the baseline moving
        if skip_replay {
            let second: String = ts_str.chars().take(19).collect();
            if Some(&second) == replay_second.as_ref() {
                if let Some(t) = total {
                    prev_totals = Some(t);
                }
                continue;
            }
            skip_replay = false;
        }
        let usage = last.or_else(|| total.map(|t| codex_usage_sub(t, prev_totals)));
        if let Some(t) = total {
            prev_totals = Some(t);
        }
        let Some(mut u) = usage else { continue };
        if u.input + u.cached + u.output + u.reasoning == 0 {
            continue;
        }
        let Some(ts) = parse_ts(&ts_str) else { continue };
        u.cached = u.cached.min(u.input); // input is INCLUSIVE of cached
        let model = codex_model_of(Some(&payload))
            .or_else(|| codex_model_of(info))
            .or_else(|| current_model.clone())
            .unwrap_or_else(|| "gpt-5".to_string());
        out.push((u, ts, model));
    }
}

/// Collect a work dir's Codex rollout files: sessions/ plus archived_sessions/, where an archived
/// copy of the same relative path loses to the active sessions/ copy.
pub(super) fn codex_files(root: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = vec![];
    let mut seen_rel: HashSet<PathBuf> = HashSet::new();
    for sub in ["sessions", "archived_sessions"] {
        let dir = root.join(sub);
        let mut files = vec![];
        collect_jsonl(&dir, 0, &mut files);
        files.sort();
        for f in files {
            // Grok Build shares the sessions/ root but keys children by percent-encoded cwd
            // (`%2FUsers%2F…/<uuid>/chat_history.jsonl` + events/updates sidecar jsonl). Those
            // must never hit the Codex token parser — wasteful and would mix formats if a line
            // ever looked like a token_count event. Skip any path under a Grok-encoded dir.
            if f.components().any(|c| crate::grok::is_cwd_dir_name(&c.as_os_str().to_string_lossy())) {
                continue;
            }
            let rel = f.strip_prefix(&dir).map(|p| p.to_path_buf()).unwrap_or_else(|_| f.clone());
            if seen_rel.insert(rel) {
                out.push(f);
            }
        }
    }
    out
}
