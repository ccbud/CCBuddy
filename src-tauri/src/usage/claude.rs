// Claude Code (projects/ tree) line parsing and the global ccusage de-dup. Moved verbatim from
// usage.rs.

use serde_json::Value;
use std::collections::HashMap;

use super::model::UsageRec;
use super::roots::parse_ts;

// ---------------------------------------------------------------------------
// Claude Code (projects/ tree)
// ---------------------------------------------------------------------------

pub(super) struct ClaudeRec {
    pub(super) id: Option<String>,
    pub(super) request_id: Option<String>,
    pub(super) sidechain: bool,
    pub(super) rec: UsageRec,
}

/// Parse one history line into a usage entry. Requires numeric `message.usage.input_tokens` /
/// `output_tokens` and a parseable `timestamp`; everything else is optional.
pub(super) fn parse_claude_line(line: &str) -> Option<ClaudeRec> {
    // cheap prefilter before JSON parse (ccusage scans for the same marker)
    if !line.contains("\"usage\"") {
        return None;
    }
    let r: Value = serde_json::from_str(line).ok()?;
    let m = r.get("message")?;
    let u = m.get("usage")?;
    let input = u.get("input_tokens")?.as_i64()?;
    let output = u.get("output_tokens")?.as_i64()?;
    let cache_read = u.get("cache_read_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
    // nested ephemeral breakdown wins over the flat cache_creation_input_tokens
    let cache_creation = match u.get("cache_creation").filter(|v| v.is_object()) {
        Some(b) => {
            b.get("ephemeral_5m_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0)
                + b.get("ephemeral_1h_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0)
        }
        None => u.get("cache_creation_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
    };
    if input + output + cache_read + cache_creation <= 0 {
        return None; // zero rows (synthetic error turns) carry no token information
    }
    let ts = r.get("timestamp").and_then(|v| v.as_str()).and_then(parse_ts)?;
    let speed_fast = u.get("speed").and_then(|v| v.as_str()) == Some("fast");
    let model = m.get("model").and_then(|v| v.as_str()).and_then(|s| {
        if s.is_empty() || s == "<synthetic>" {
            None // tokens still count; no model attribution
        } else if speed_fast {
            Some(format!("{}-fast", s))
        } else {
            Some(s.to_string())
        }
    });
    Some(ClaudeRec {
        id: m.get("id").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from),
        request_id: r.get("requestId").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from),
        sidechain: r.get("isSidechain").and_then(|v| v.as_bool()).unwrap_or(false),
        rec: UsageRec { ts, model, input, output, cache_read, cache_creation },
    })
}

/// Message ids that older ccbud gateway builds stamped on EVERY translated response — known
/// non-unique, so they must never act as a de-dup key (an id-keyed de-dup would collapse whole
/// weeks of history written through the gateway into a single counted turn).
pub(super) fn degenerate_id(id: &str) -> bool {
    id == "msg_ccbud" || id == "chatcmpl-ccbud" || id == "resp_ccbud"
}

/// Global de-dup, ccusage semantics: key (message.id, requestId); entries without an id are always
/// kept. A miss on the exact key falls back to the id-only bucket when either side is a sidechain
/// (a `/btw` replay reuses the parent's message.id under a new requestId). On a duplicate the
/// non-sidechain copy wins, then the higher token total.
pub(super) fn dedup_claude(recs: Vec<ClaudeRec>) -> Vec<ClaudeRec> {
    let mut kept: Vec<ClaudeRec> = vec![];
    let mut by_exact: HashMap<(String, Option<String>), usize> = HashMap::new();
    let mut by_id: HashMap<String, usize> = HashMap::new();
    for cand in recs {
        let Some(id) = cand.id.clone().filter(|i| !degenerate_id(i)) else {
            kept.push(cand);
            continue;
        };
        let exact = (id.clone(), cand.request_id.clone());
        let slot = by_exact.get(&exact).copied().or_else(|| {
            by_id.get(&id).copied().filter(|&i| cand.sidechain || kept[i].sidechain)
        });
        match slot {
            Some(i) => {
                let cur = &kept[i];
                let replace = (cur.sidechain && !cand.sidechain)
                    || (cur.sidechain == cand.sidechain && cand.rec.total() > cur.rec.total());
                if replace {
                    kept[i] = cand;
                }
                by_exact.insert(exact, i);
            }
            None => {
                let i = kept.len();
                by_exact.insert(exact, i);
                by_id.entry(id).or_insert(i);
                kept.push(cand);
            }
        }
    }
    kept
}
