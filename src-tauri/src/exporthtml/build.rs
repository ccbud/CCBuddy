// The export data document: the Claude path and the foreign-session path (Codex / Grok /
// Copilot / Antigravity / Qoder). Moved verbatim from exporthtml.rs.

use serde_json::{json, Value};
use std::path::Path;

use super::parse::{cap_content, parse_jsonl_result};
use super::session::{read_subagents, shape_session};
use super::shape::{base_name, first_user_text};

// Non-Claude session detail → the export data shape (messages re-capped + field names the
// viewer runtime reads: model / usage{in,out,cacheRead} / stop). `assistant` labels turns on
// the exported page (Codex / Grok / Copilot / Antigravity).
fn build_from_session(sess: Value, assistant: &str) -> Value {
    let m = sess.get("meta").cloned().unwrap_or_else(|| json!({}));
    let messages: Vec<Value> = sess
        .get("messages")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .map(|msg| {
                    let mut out = json!({
                        "role": msg.get("role").cloned().unwrap_or(Value::Null),
                        "content": cap_content(msg.get("content").unwrap_or(&Value::Null)),
                        "ts": msg.get("ts").cloned().unwrap_or(Value::Null),
                        "meta": msg
                            .get("meta")
                            .or_else(|| msg.get("_meta"))
                            .and_then(|v| v.as_bool())
                            .unwrap_or(false),
                    });
                    let o = out.as_object_mut().unwrap();
                    if let Some(md) = msg.get("modelActual") {
                        o.insert("model".into(), md.clone());
                    }
                    if let Some(u) = msg.get("usage") {
                        let mut usage = json!({
                            "in": u.get("inputTokens").and_then(|v| v.as_i64()).unwrap_or(0),
                            "out": u.get("outputTokens").and_then(|v| v.as_i64()).unwrap_or(0),
                            "cacheRead": u.get("cacheRead").and_then(|v| v.as_i64()).unwrap_or(0),
                            "cacheCreation": u.get("cacheCreation").and_then(|v| v.as_i64()).unwrap_or(0),
                        });
                        let usage_object = usage.as_object_mut().unwrap();
                        for field in ["credits", "originalCredits", "contextUsageRatio"] {
                            if let Some(value) = u.get(field).filter(|value| value.is_number()) {
                                usage_object.insert(field.to_string(), value.clone());
                            }
                        }
                        o.insert(
                            "usage".into(),
                            usage,
                        );
                    }
                    out
                })
                .collect()
        })
        .unwrap_or_default();
    let t = m.get("totals").cloned().unwrap_or_else(|| json!({}));
    let title = m
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    json!({
        "meta": {
            "title": if title.is_empty() { "(conversation)".to_string() } else { title },
            "assistant": assistant,
            "model": m.get("model").cloned().unwrap_or(Value::Null),
            "project": m.get("project").cloned().unwrap_or(Value::Null),
            "cwd": m.get("cwd").cloned().unwrap_or(Value::Null),
            "branch": m.get("gitBranch").cloned().unwrap_or(Value::Null),
            "sessionId": m.get("sessionId").cloned().unwrap_or(Value::Null),
            "version": m.get("version").cloned().unwrap_or(Value::Null),
            "count": messages.len(),
            "turns": t.get("turns").cloned().unwrap_or(json!(0)),
            "inTok": t.get("in").cloned().unwrap_or(json!(0)),
            "outTok": t.get("out").cloned().unwrap_or(json!(0)),
            "cacheTok": t.get("cacheRead").cloned().unwrap_or(json!(0)),
            "credits": t.get("credits").cloned().unwrap_or(Value::Null),
            "tokenUsageAvailable": t.get("tokenUsageAvailable").cloned().unwrap_or(json!(true)),
            "subagentCount": 0,
            "firstTs": m.get("firstTs").cloned().unwrap_or(Value::Null),
            "lastTs": m.get("lastTs").cloned().unwrap_or(Value::Null),
        },
        "messages": messages,
        "subagents": {},
    })
}

pub fn build_data(file: &str) -> Value {
    let path = Path::new(file);
    let qoder = crate::qoder::looks_qoder_path(path);
    // Antigravity first — it's SQLite and its shaper opens the DB itself. Every other source
    // reads the transcript here, and a failed MAIN read returns the structured error (the export
    // command surfaces it) instead of silently exporting an empty page.
    if matches!(crate::history::foreign_kind(path), Some(crate::history::Foreign::Antigravity)) {
        return build_from_session(crate::antigravity::session_from(file), "Antigravity");
    }
    let recs = match parse_jsonl_result(path) {
        Ok(recs) => recs,
        Err(error) => return crate::history::session_read_error(path, &error),
    };
    match crate::history::foreign_kind(path) {
        Some(crate::history::Foreign::Grok) => {
            return build_from_session(crate::grok::session_from_recs(file, &recs), "Grok");
        }
        Some(crate::history::Foreign::Copilot) => {
            return build_from_session(crate::copilot::session_from_recs(file, &recs), "Copilot");
        }
        _ => {}
    }
    if crate::codex::looks_codex(&recs) {
        return build_from_session(crate::codex::session_from_recs(file, &recs), "Codex");
    }
    // Qoder sessions are Claude-format (the shaping below applies as-is) — brand the exported
    // page and prefer qoder's own stored title over first-user-text.
    let meta_rec = recs
        .iter()
        .find(|r| r.get("cwd").is_some())
        .or_else(|| recs.iter().find(|r| r.get("sessionId").is_some()));
    let s = shape_session(&recs);
    let top_level_cwd = meta_rec
        .and_then(|r| r.get("cwd"))
        .and_then(|v| v.as_str())
        .map(str::to_string);
    let cwd = if qoder {
        crate::qoder::working_dir_from(&recs).or(top_level_cwd)
    } else {
        top_level_cwd
    };
    let title = {
        let t = (if qoder {
            crate::qoder::session_title_from(&recs)
        } else {
            None
        })
        .unwrap_or_else(|| first_user_text(&s.messages));
        if t.is_empty() {
            "(conversation)".to_string()
        } else {
            t
        }
    };
    let model = if qoder {
        crate::qoder::model_from(&recs).or(s.model.clone())
    } else {
        s.model.clone()
    };
    let stem = path.file_stem().and_then(|x| x.to_str()).unwrap_or("");
    let mut subagents = read_subagents(path);
    if let Some(map) = subagents.as_object_mut() {
        // The spawning Skill tool_use overrides the sentinel fallback (mirrors exportHtml.js).
        crate::history::apply_skill_names(&s.messages, map);
    }
    json!({
        "meta": {
            "title": title,
            // The viewer runtime labels turns `meta.assistant || 'Claude'`.
            "assistant": if qoder { json!("Qoder") } else { Value::Null },
            "model": model,
            "project": cwd.as_deref().map(base_name),
            "cwd": cwd,
            "branch": meta_rec.and_then(|r| r.get("gitBranch")).cloned().unwrap_or(Value::Null),
            "sessionId": meta_rec.and_then(|r| r.get("sessionId")).and_then(|v| v.as_str()).unwrap_or(stem),
            "version": meta_rec.and_then(|r| r.get("version")).cloned().unwrap_or(Value::Null),
            "count": s.messages.len(),
            "turns": s.totals.3,
            "inTok": s.totals.0, "outTok": s.totals.1, "cacheTok": s.totals.2,
            "credits": s.credits,
            "tokenUsageAvailable": s.token_usage_available,
            "subagentCount": subagents.as_object().map(|o| o.len()).unwrap_or(0),
            "firstTs": s.first_ts, "lastTs": s.last_ts,
        },
        "messages": s.messages,
        "subagents": subagents,
    })
}
