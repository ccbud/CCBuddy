// Whole-session shaping (messages + totals + timestamps) and the subagent transcript scan.
// Moved verbatim from exporthtml.rs.

use serde_json::{json, Value};
use std::fs;
use std::path::Path;

use super::parse::parse_jsonl;
use super::shape::line_to_msg;

pub(super) struct Shaped {
    pub(super) messages: Vec<Value>,
    pub(super) model: Option<String>,
    pub(super) totals: (i64, i64, i64, i64),
    pub(super) cache_creation: i64,
    pub(super) credits: Option<f64>,
    pub(super) token_usage_available: bool,
    pub(super) first_ts: Option<String>,
    pub(super) last_ts: Option<String>,
}
pub(super) fn shape_session(recs: &[Value]) -> Shaped {
    let mut messages = vec![];
    let (mut tin, mut tout, mut tcr, mut tcc, mut turns) = (0i64, 0i64, 0i64, 0i64, 0i64);
    let mut credits = 0.0f64;
    let mut has_credits = false;
    let mut model = None;
    let mut first_ts = None;
    let mut last_ts = None;
    for r in recs {
        let lm = match line_to_msg(r) {
            Some(m) => m,
            None => continue,
        };
        if lm.get("meta").and_then(|v| v.as_bool()).unwrap_or(false) {
            continue;
        }
        if let Some(ts) = lm.get("ts").and_then(|v| v.as_str()) {
            if first_ts.is_none() {
                first_ts = Some(ts.to_string());
            }
            last_ts = Some(ts.to_string());
        }
        if let Some(md) = lm.get("model").and_then(|v| v.as_str()) {
            model = Some(md.to_string());
        }
        if let Some(u) = lm.get("usage").filter(|u| u.is_object()) {
            tin += u.get("in").and_then(|v| v.as_i64()).unwrap_or(0);
            tout += u.get("out").and_then(|v| v.as_i64()).unwrap_or(0);
            tcr += u.get("cacheRead").and_then(|v| v.as_i64()).unwrap_or(0);
            tcc += u.get("cacheCreation").and_then(|v| v.as_i64()).unwrap_or(0);
            if let Some(value) = u.get("credits").and_then(|v| v.as_f64()) {
                credits += value;
                has_credits = true;
            }
            turns += 1;
        }
        messages.push(lm);
    }
    Shaped {
        messages,
        model,
        totals: (tin, tout, tcr, turns),
        cache_creation: tcc,
        credits: has_credits.then_some(credits),
        token_usage_available: !(has_credits && tin == 0 && tout == 0 && tcr == 0 && tcc == 0),
        first_ts,
        last_ts,
    }
}

pub(super) fn read_subagents(file: &Path) -> Value {
    let qoder = crate::qoder::looks_qoder_path(file);
    let dir = file.parent().map(|p| {
        p.join(file.file_stem().and_then(|s| s.to_str()).unwrap_or(""))
            .join("subagents")
    });
    let dir = match dir {
        Some(d) => d,
        None => return json!({}),
    };
    let entries = match fs::read_dir(&dir) {
        Ok(e) => e,
        Err(_) => return json!({}),
    };
    let mut agent_names: Vec<String> = entries
        .flatten()
        .map(|ent| ent.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with("agent-") && name.ends_with(".jsonl"))
        .collect();
    agent_names.sort();
    // A protected qoder session's subagent transcripts + meta sidecars warm in one helper batch.
    if qoder {
        let mut warm: Vec<std::path::PathBuf> = vec![];
        for name in &agent_names {
            warm.push(dir.join(name));
            let agent_id = name.trim_start_matches("agent-").trim_end_matches(".jsonl");
            warm.push(dir.join(format!("agent-{}.meta.json", agent_id)));
        }
        crate::qoder::prefetch(&warm);
    }
    let mut by_tool = serde_json::Map::new();
    for name in agent_names {
        let agent_id = name
            .trim_start_matches("agent-")
            .trim_end_matches(".jsonl")
            .to_string();
        let meta_path = dir.join(format!("agent-{}.meta.json", agent_id));
        let meta_raw = if qoder {
            crate::qoder::read_text(&meta_path)
        } else {
            fs::read_to_string(&meta_path)
        };
        let meta: Value = meta_raw
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or(json!({}));
        let recs = parse_jsonl(&dir.join(&name));
        let shaped = shape_session(&recs);
        let key = meta
            .get("toolUseId")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| format!("agent:{}", agent_id));
        by_tool.insert(
            key,
            json!({
                "agentId": agent_id,
                "type": meta.get("agentType").or_else(|| meta.get("subagent_type")).and_then(|v| v.as_str()).unwrap_or("agent"),
                "description": meta.get("description").and_then(|v| v.as_str()).unwrap_or(""),
                "skill": crate::history::skill_from_recs(&recs),
                "count": shaped.messages.len(),
                "totals": {
                    "in": shaped.totals.0,
                    "out": shaped.totals.1,
                    "cacheRead": shaped.totals.2,
                    "cacheCreation": shaped.cache_creation,
                    "turns": shaped.totals.3,
                    "credits": shaped.credits,
                    "tokenUsageAvailable": shaped.token_usage_available,
                },
                "messages": shaped.messages,
            }),
        );
    }
    Value::Object(by_tool)
}
