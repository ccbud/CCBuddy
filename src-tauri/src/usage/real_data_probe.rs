use super::build::build_data;
use super::claude::{degenerate_id, parse_claude_line};
use super::model::{collect_jsonl, LossyLines};
use super::query::query;
use super::roots::{expand_tilde, parse_ts};
use chrono::Local;
use serde_json::{json, Value};

// Diagnostic harness (not an assertion): aggregate a REAL history dir and print per-range
// totals, so the implementation can be diffed against `ccusage` on the same data.
// Run: CCBUD_PROBE_DIR=~/.claude cargo test --lib probe_real_dir -- --ignored --nocapture
#[test]
#[ignore]
fn probe_real_dir() {
    let Ok(dir) = std::env::var("CCBUD_PROBE_DIR") else {
        eprintln!("set CCBUD_PROBE_DIR");
        return;
    };
    // parse-level diagnostics: where do lines fall out of the pipeline?
    let root = expand_tilde(&dir);
    let mut files = vec![];
    collect_jsonl(&root.join("projects"), 0, &mut files);
    let (mut n_files, mut n_usage_lines, mut n_parsed, mut n_no_ts, mut n_degen) = (0u64, 0u64, 0u64, 0u64, 0u64);
    for file in &files {
        n_files += 1;
        let Some(mut lines) = LossyLines::open(file) else { continue };
        while let Some(l) = lines.next_line() {
            let l = l.trim();
            if !l.contains("\"usage\"") {
                continue;
            }
            n_usage_lines += 1;
            match parse_claude_line(l) {
                Some(rec) => {
                    n_parsed += 1;
                    if rec.id.as_deref().map(degenerate_id).unwrap_or(false) {
                        n_degen += 1;
                    }
                }
                None => {
                    // distinguish the "usage present but timestamp bad/missing" case
                    if let Ok(v) = serde_json::from_str::<Value>(l) {
                        if v.get("message").and_then(|m| m.get("usage")).is_some()
                            && v.get("timestamp").and_then(|t| t.as_str()).and_then(parse_ts).is_none()
                        {
                            n_no_ts += 1;
                        }
                    }
                }
            }
        }
    }
    eprintln!(
        "claude files={} usage-lines={} parsed={} dropped-no-ts={} degenerate-id={}",
        n_files, n_usage_lines, n_parsed, n_no_ts, n_degen
    );
    let config = json!({ "historyDirs": [dir] });
    let days = build_data(&config, "all");
    let now = Local::now().timestamp_millis();
    let mut keys: Vec<_> = days.keys().cloned().collect();
    keys.sort();
    for k in &keys {
        let d = &days[k];
        eprintln!("{}  tokens={} in={} out={} cr={} cc={} req={}", k, d.tokens, d.input, d.output, d.cache_read, d.cache_creation, d.requests);
    }
    for range in ["1d", "7d", "30d", "all"] {
        let q = query(&days, range, now);
        eprintln!("range {:>3}: tokens={} requests={}", range, q["tokens"], q["requests"]);
    }
}
