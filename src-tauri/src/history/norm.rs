use serde_json::{json, Value};

fn usage_of(u: &Value) -> Value {
    let mut usage = json!({
        "inputTokens": u.get("input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
        "outputTokens": u.get("output_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
        "cacheRead": u.get("cache_read_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
        "cacheCreation": u.get("cache_creation_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
    });
    let object = usage.as_object_mut().unwrap();
    // Qoder supplies billing/context facts alongside its zeroed token counters. Keep them on the
    // per-turn usage object without adding empty fields to ordinary Claude Code messages.
    for (source, target) in [
        ("credits", "credits"),
        ("original_credits", "originalCredits"),
        ("context_usage_ratio", "contextUsageRatio"),
    ] {
        if let Some(value) = u.get(source).filter(|value| value.is_number()) {
            object.insert(target.to_string(), value.clone());
        }
    }
    usage
}

pub(super) fn line_to_message(rec: &Value) -> Option<Value> {
    let t = rec.get("type").and_then(|v| v.as_str())?;
    if t != "user" && t != "assistant" {
        return None;
    }
    let m = rec.get("message")?;
    let role = m.get("role").and_then(|v| v.as_str())?;
    let mut out = json!({
        "role": role,
        "content": m.get("content").cloned().unwrap_or(Value::Null),
        "_ts": rec.get("timestamp").cloned().unwrap_or(Value::Null),
        "_sidechain": rec.get("isSidechain").and_then(|v| v.as_bool()).unwrap_or(false),
        "_meta": rec.get("isMeta").and_then(|v| v.as_bool()).unwrap_or(false),
    });
    if t == "assistant" {
        let o = out.as_object_mut().unwrap();
        o.insert("_model".into(), m.get("model").cloned().unwrap_or(Value::Null));
        o.insert("_usage".into(), m.get("usage").map(usage_of).unwrap_or(Value::Null));
        o.insert("_stopReason".into(), m.get("stop_reason").cloned().unwrap_or(Value::Null));
    }
    Some(out)
}

pub(super) struct Shaped {
    pub(super) messages: Vec<Value>,
    pub(super) totals: Value,
    pub(super) model: Option<String>,
    pub(super) first_ts: Option<String>,
    pub(super) last_ts: Option<String>,
}

/// The renderer's normalized session shape shared by every non-Claude source (Codex, Grok,
/// Copilot, Antigravity): Anthropic-style messages (`role` + content blocks of
/// text/thinking/tool_use/tool_result) plus the session-level facts each format can recover.
pub struct Norm {
    pub messages: Vec<Value>,
    pub totals: Value,
    pub model: Option<String>,
    pub first_ts: Option<String>,
    pub last_ts: Option<String>,
    pub cwd: Option<String>,
    pub session_id: Option<String>,
    pub thread_id: Option<String>,
    pub parent_thread_id: Option<String>,
    pub forked_from_id: Option<String>,
    pub is_subagent: bool,
    pub agent_path: Option<String>,
    pub agent_nickname: Option<String>,
    pub agent_role: Option<String>,
    pub agent_depth: Option<i64>,
    pub git_branch: Option<String>,
    pub version: Option<String>,
}

impl Default for Norm {
    fn default() -> Self {
        Norm {
            messages: vec![],
            totals: json!({ "in": 0, "out": 0, "cacheRead": 0, "cacheCreation": 0, "turns": 0 }),
            model: None,
            first_ts: None,
            last_ts: None,
            cwd: None,
            session_id: None,
            thread_id: None,
            parent_thread_id: None,
            forked_from_id: None,
            is_subagent: false,
            agent_path: None,
            agent_nickname: None,
            agent_role: None,
            agent_depth: None,
            git_branch: None,
            version: None,
        }
    }
}

/// data-URL image → Claude-style image source block, else None.
pub(crate) fn image_block(url: &str) -> Option<Value> {
    let rest = url.strip_prefix("data:")?;
    let (mime, b64) = rest.split_once(";base64,")?;
    Some(json!({ "type": "image", "source": { "type": "base64", "media_type": mime, "data": b64 } }))
}

pub(super) fn shape_messages(recs: &[Value]) -> Shaped {
    let mut messages = vec![];
    let (mut tin, mut tout, mut tcr, mut tcc, mut turns) = (0i64, 0i64, 0i64, 0i64, 0i64);
    let mut credits = 0.0f64;
    let mut has_credits = false;
    let mut model: Option<String> = None;
    let mut first_ts: Option<String> = None;
    let mut last_ts: Option<String> = None;
    for r in recs {
        let lm = match line_to_message(r) {
            Some(m) => m,
            None => continue,
        };
        if lm.get("_meta").and_then(|v| v.as_bool()).unwrap_or(false) {
            continue;
        }
        let ts = lm.get("_ts").and_then(|v| v.as_str()).map(|s| s.to_string());
        if let Some(t) = &ts {
            if first_ts.is_none() {
                first_ts = Some(t.clone());
            }
            last_ts = Some(t.clone());
        }
        let mut msg = json!({ "role": lm.get("role").cloned().unwrap_or(Value::Null), "content": lm.get("content").cloned().unwrap_or(Value::Null) });
        let mo = msg.as_object_mut().unwrap();
        if lm.get("_sidechain").and_then(|v| v.as_bool()).unwrap_or(false) {
            mo.insert("isSidechain".into(), json!(true));
        }
        if let Some(t) = &ts {
            mo.insert("ts".into(), json!(t));
        }
        if r.get("type").and_then(|v| v.as_str()) == Some("assistant") {
            if let Some(md) = lm.get("_model").and_then(|v| v.as_str()) {
                mo.insert("modelActual".into(), json!(md));
                model = Some(md.to_string());
            }
            let u = lm.get("_usage").cloned().unwrap_or(Value::Null);
            if u.is_object() {
                mo.insert("usage".into(), u.clone());
                tin += u.get("inputTokens").and_then(|v| v.as_i64()).unwrap_or(0);
                tout += u.get("outputTokens").and_then(|v| v.as_i64()).unwrap_or(0);
                tcr += u.get("cacheRead").and_then(|v| v.as_i64()).unwrap_or(0);
                tcc += u.get("cacheCreation").and_then(|v| v.as_i64()).unwrap_or(0);
                if let Some(value) = u.get("credits").and_then(|v| v.as_f64()) {
                    credits += value;
                    has_credits = true;
                }
                turns += 1;
            }
            if let Some(sr) = lm.get("_stopReason").and_then(|v| v.as_str()) {
                mo.insert("stopReason".into(), json!(sr));
            }
        }
        messages.push(msg);
    }
    let mut totals = json!({ "in": tin, "out": tout, "cacheRead": tcr, "cacheCreation": tcc, "turns": turns });
    if has_credits {
        let totals = totals.as_object_mut().unwrap();
        totals.insert("credits".into(), json!(credits));
        // Qoder's source log may omit usable token accounting while still providing real credits.
        // Flag that state so the UI does not misrepresent unavailable token counts as zero usage.
        if tin == 0 && tout == 0 && tcr == 0 && tcc == 0 {
            totals.insert("tokenUsageAvailable".into(), json!(false));
        }
    }
    Shaped {
        messages,
        totals,
        model,
        first_ts,
        last_ts,
    }
}
