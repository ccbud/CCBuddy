use serde_json::{json, Value};

use super::list::list_sessions;
use super::session::get_session;

// Diagnostic harness (not an assertion): list + open REAL foreign-CLI sessions so the
// shapers can be eyeballed against live ~/.grok, ~/.copilot, ~/.gemini/antigravity-cli.
// Run: CCBUD_PROBE_FOREIGN="~/.grok,~/.copilot,~/.gemini/antigravity-cli" \
//      cargo test --lib probe_foreign_dirs -- --ignored --nocapture
#[test]
#[ignore]
fn probe_foreign_dirs() {
    let Ok(dirs) = std::env::var("CCBUD_PROBE_FOREIGN") else {
        eprintln!("set CCBUD_PROBE_FOREIGN=dir1,dir2,…");
        return;
    };
    let list: Vec<&str> = dirs.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
    let config = json!({ "historyDirs": list });
    let sessions = list_sessions(&config, "all", 500);
    eprintln!("== {} sessions across {:?}", sessions.len(), list);
    let mut by_source: std::collections::HashMap<String, i64> = std::collections::HashMap::new();
    for s in &sessions {
        *by_source
            .entry(s.get("source").and_then(|v| v.as_str()).unwrap_or("?").to_string())
            .or_insert(0) += 1;
    }
    eprintln!("== by source: {:?}", by_source);
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    for s in &sessions {
        let src = s.get("source").and_then(|v| v.as_str()).unwrap_or("?").to_string();
        if !seen.insert(src.clone()) {
            continue;
        }
        let file = s.get("file").and_then(|v| v.as_str()).unwrap_or("");
        eprintln!(
            "-- [{}] {} | cwd={} | title={:?}",
            src,
            file,
            s.get("cwd").and_then(|v| v.as_str()).unwrap_or("-"),
            s.get("title").and_then(|v| v.as_str()).unwrap_or("-")
        );
        let detail = get_session(file);
        let meta = detail.get("meta").cloned().unwrap_or(Value::Null);
        let msgs = detail.get("messages").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0);
        eprintln!(
            "   detail: assistant={:?} messages={} totals={} firstTs={:?}",
            meta.get("assistant").and_then(|v| v.as_str()),
            msgs,
            meta.get("totals").map(|t| t.to_string()).unwrap_or_default(),
            meta.get("firstTs").and_then(|v| v.as_str())
        );
        if let Some(arr) = detail.get("messages").and_then(|v| v.as_array()) {
            for m in arr.iter().take(4) {
                let role = m.get("role").and_then(|v| v.as_str()).unwrap_or("?");
                let kinds: Vec<String> = m
                    .get("content")
                    .and_then(|c| c.as_array())
                    .map(|a| {
                        a.iter()
                            .map(|b| b.get("type").and_then(|t| t.as_str()).unwrap_or("?").to_string())
                            .collect()
                    })
                    .unwrap_or_default();
                eprintln!("   msg {} {:?}", role, kinds);
            }
        }
    }
}
