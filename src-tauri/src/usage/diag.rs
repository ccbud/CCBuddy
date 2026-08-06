// The scan diagnostic line and the module's public entry point. Moved verbatim from usage.rs.

use chrono::Local;
use serde_json::Value;

use super::build::{build_data, build_data_cached};
use super::claude::{dedup_claude, degenerate_id, parse_claude_line, ClaudeRec};
use super::codex::codex_files;
use super::model::{collect_jsonl, LossyLines};
use super::query::query;
use super::roots::{active_roots, parse_ts};

/// One-line scan diagnostic for the gateway log — which dirs resolved, how many files/lines
/// reached each pipeline stage, and the day span. Makes an empty/partial aggregation visible
/// without a debugger ("only today shows up" → the counters name the stage that dropped it).
pub fn diag(config: &Value, active: &str) -> String {
    let roots = active_roots(config, active);
    let mut claude_files = 0usize;
    let mut codex_file_count = 0usize;
    let (mut usage_lines, mut parsed, mut zero_rows, mut no_ts, mut degen) = (0usize, 0usize, 0usize, 0usize, 0usize);
    let mut recs: Vec<ClaudeRec> = vec![];
    for root in &roots {
        let mut files = vec![];
        collect_jsonl(&root.join("projects"), 0, &mut files);
        claude_files += files.len();
        for f in &files {
            let Some(mut lines) = LossyLines::open(f) else { continue };
            while let Some(l) = lines.next_line() {
                let l = l.trim();
                if !l.contains("\"usage\"") {
                    continue;
                }
                usage_lines += 1;
                match parse_claude_line(l) {
                    Some(r) => {
                        parsed += 1;
                        if r.id.as_deref().map(degenerate_id).unwrap_or(false) {
                            degen += 1;
                        }
                        recs.push(r);
                    }
                    None => {
                        if let Ok(v) = serde_json::from_str::<Value>(l) {
                            if v.get("message").and_then(|m| m.get("usage")).is_some() {
                                if v.get("timestamp").and_then(|t| t.as_str()).and_then(parse_ts).is_none() {
                                    no_ts += 1;
                                } else {
                                    zero_rows += 1;
                                }
                            }
                        }
                    }
                }
            }
        }
        codex_file_count += codex_files(root).len();
    }
    let kept = dedup_claude(recs).len();
    let days = build_data(config, active);
    let mut keys: Vec<_> = days.keys().cloned().collect();
    keys.sort();
    let span = match (keys.first(), keys.last()) {
        (Some(a), Some(b)) => format!("{}..{}", a, b),
        _ => "-".to_string(),
    };
    format!(
        "usage scan: active={} roots={:?} claude-files={} codex-files={} usage-lines={} parsed={} kept={} days={} span={} dropped(no-ts)={} dropped(zero/invalid)={} degenerate-ids={}",
        active,
        roots.iter().map(|r| r.to_string_lossy().to_string()).collect::<Vec<_>>(),
        claude_files, codex_file_count, usage_lines, parsed, kept, keys.len(), span, no_ts, zero_rows, degen
    )
}

/// Public entry: aggregate the active dirs and return the usage stats payload for `range`.
pub fn usage_get(config: &Value, active: &str, range: &str) -> Value {
    let days = build_data_cached(config, active);
    let now = Local::now().timestamp_millis();
    query(&days, range, now)
}
