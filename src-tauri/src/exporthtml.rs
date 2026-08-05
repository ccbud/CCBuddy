// Standalone conversation export → a single self-contained .html viewer. Rust port of exportHtml.js.
//
// Embeds the conversation as JSON plus a Claude-design skin (light/dark) + a client runtime
// (render + theme + search + expandable tools/subagents), with marked + highlight.js vendored.
// Heavy content fields are capped so the embedded JSON stays bounded.

#![allow(dead_code)]

use serde_json::{json, Value};
use std::fs;
use std::path::Path;

const SKIN: &str = include_str!("../../src/main/export-assets/skin.css");
const RUNTIME: &str = include_str!("../../src/main/export-assets/runtime.js");
const MARKED: &str = include_str!("../../src/renderer/vendor/marked.umd.js");
const HLJS: &str = include_str!("../../src/renderer/vendor/highlight.min.js");
const HLJS_CSS: &str = include_str!("../../src/renderer/vendor/hljs-dark.css");

const CAP_TEXT: usize = 24000;
const CAP_THINKING: usize = 16000;
const CAP_RESULT: usize = 24000;
const CAP_PROMPT: usize = 9000;
const CAP_CONTENT: usize = 14000;

fn cap(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        let truncated: String = s.chars().take(n).collect();
        let dropped = s.chars().count() - n;
        format!("{}\n…[truncated {} chars]", truncated, dropped)
    } else {
        s.to_string()
    }
}

fn parse_jsonl(file: &Path) -> Vec<Value> {
    let qoder = crate::qoder::looks_qoder_path(file);
    let raw = match if qoder {
        crate::qoder::read_text(file)
    } else {
        fs::read_to_string(file)
    } {
        Ok(s) => s,
        Err(_) => return vec![],
    };
    let records: Vec<Value> = raw
        .split('\n')
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .collect();
    if qoder {
        crate::qoder::normalize_records(&records)
    } else {
        records
    }
}

fn usage_of(u: &Value) -> Value {
    json!({
        "in": u.get("input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
        "out": u.get("output_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
        "cacheRead": u.get("cache_read_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
        "cacheCreation": u.get("cache_creation_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0),
    })
}

fn cap_content(content: &Value) -> Value {
    if let Some(s) = content.as_str() {
        return json!(cap(s, CAP_TEXT));
    }
    let arr = match content.as_array() {
        Some(a) => a,
        None => return content.clone(),
    };
    let mapped: Vec<Value> = arr
        .iter()
        .map(|b| {
            let ty = b.get("type").and_then(|t| t.as_str()).unwrap_or("");
            match ty {
                "text" => json!({ "type": "text", "text": cap(b.get("text").and_then(|t| t.as_str()).unwrap_or(""), CAP_TEXT) }),
                "thinking" => json!({ "type": "thinking", "thinking": cap(b.get("thinking").and_then(|t| t.as_str()).unwrap_or(""), CAP_THINKING) }),
                "tool_use" => {
                    let mut input = b.get("input").cloned().unwrap_or(json!({}));
                    if let Some(obj) = input.as_object_mut() {
                        if let Some(p) = obj.get("prompt").and_then(|v| v.as_str()) {
                            let c = cap(p, CAP_PROMPT);
                            obj.insert("prompt".into(), json!(c));
                        }
                        if let Some(p) = obj.get("content").and_then(|v| v.as_str()) {
                            let c = cap(p, CAP_CONTENT);
                            obj.insert("content".into(), json!(c));
                        }
                        if let Some(p) = obj.get("patch").and_then(|v| v.as_str()) {
                            let c = cap(p, CAP_CONTENT); // codex ApplyPatch envelopes can be huge
                            obj.insert("patch".into(), json!(c));
                        }
                        if let Some(p) = obj.get("code").and_then(|v| v.as_str()) {
                            let c = cap(p, CAP_CONTENT); // code-mode Script bodies
                            obj.insert("code".into(), json!(c));
                        }
                    }
                    json!({ "type": "tool_use", "id": b.get("id").cloned().unwrap_or(Value::Null), "name": b.get("name").cloned().unwrap_or(Value::Null), "input": input })
                }
                "tool_result" => {
                    let c = match b.get("content") {
                        Some(Value::String(s)) => json!(cap(s, CAP_RESULT)),
                        Some(Value::Array(ca)) => Value::Array(
                            ca.iter()
                                .map(|x| {
                                    if x.get("type").and_then(|t| t.as_str()) == Some("text") {
                                        json!({ "type": "text", "text": cap(x.get("text").and_then(|t| t.as_str()).unwrap_or(""), CAP_RESULT) })
                                    } else {
                                        x.clone()
                                    }
                                })
                                .collect(),
                        ),
                        other => other.cloned().unwrap_or(Value::Null),
                    };
                    json!({ "type": "tool_result", "tool_use_id": b.get("tool_use_id").cloned().unwrap_or(Value::Null), "is_error": b.get("is_error").and_then(|v| v.as_bool()).unwrap_or(false), "content": c })
                }
                "image" => {
                    let oversized = b.get("source").and_then(|s| s.get("data")).and_then(|d| d.as_str()).map(|d| d.len() > 600000).unwrap_or(false);
                    if oversized {
                        json!({ "type": "image", "source": { "media_type": b.get("source").and_then(|s| s.get("media_type")).and_then(|m| m.as_str()).unwrap_or("image/png"), "oversized": true } })
                    } else {
                        b.clone()
                    }
                }
                _ => b.clone(),
            }
        })
        .collect();
    Value::Array(mapped)
}

fn line_to_msg(rec: &Value) -> Option<Value> {
    let ty = rec.get("type").and_then(|v| v.as_str())?;
    if ty != "user" && ty != "assistant" {
        return None;
    }
    let m = rec.get("message")?;
    m.get("role").and_then(|v| v.as_str())?;
    let mut out = json!({
        "role": m.get("role").cloned().unwrap_or(Value::Null),
        "content": cap_content(m.get("content").unwrap_or(&Value::Null)),
        "ts": rec.get("timestamp").cloned().unwrap_or(Value::Null),
        "meta": rec.get("isMeta").and_then(|v| v.as_bool()).unwrap_or(false),
    });
    if ty == "assistant" {
        let o = out.as_object_mut().unwrap();
        o.insert(
            "model".into(),
            m.get("model").cloned().unwrap_or(Value::Null),
        );
        o.insert(
            "usage".into(),
            m.get("usage").map(usage_of).unwrap_or(Value::Null),
        );
        o.insert(
            "stop".into(),
            m.get("stop_reason").cloned().unwrap_or(Value::Null),
        );
    }
    Some(out)
}

fn content_text(content: &Value) -> String {
    if let Some(s) = content.as_str() {
        return s.to_string();
    }
    if let Some(arr) = content.as_array() {
        return arr
            .iter()
            .filter(|b| b.get("type").and_then(|t| t.as_str()) == Some("text"))
            .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
            .collect::<Vec<_>>()
            .join(" ");
    }
    String::new()
}
fn command_label(raw: &str) -> String {
    let name = raw
        .split_once("<command-name>")
        .and_then(|(_, r)| r.split_once("</command-name>"))
        .map(|(n, _)| n.trim().to_string())
        .unwrap_or_default();
    if name.is_empty() {
        return String::new();
    }
    let args = raw
        .split_once("<command-args>")
        .and_then(|(_, r)| r.split_once("</command-args>"))
        .map(|(a, _)| a.trim().to_string())
        .unwrap_or_default();
    format!("{} {}", name, args).trim().to_string()
}
fn first_user_text(messages: &[Value]) -> String {
    let mut fallback = String::new();
    for m in messages {
        if m.get("role").and_then(|r| r.as_str()) != Some("user")
            || m.get("meta").and_then(|v| v.as_bool()).unwrap_or(false)
        {
            continue;
        }
        let raw = content_text(m.get("content").unwrap_or(&Value::Null));
        let raw = raw.trim();
        if raw.is_empty() {
            continue;
        }
        if raw.starts_with('<') {
            if fallback.is_empty() {
                fallback = command_label(raw);
            }
            continue;
        }
        let t: String = raw.split_whitespace().collect::<Vec<_>>().join(" ");
        if t.starts_with("[Request interrupted") || t.starts_with("Caveat:") {
            continue;
        }
        return t.chars().take(100).collect();
    }
    fallback.chars().take(100).collect()
}
fn base_name(p: &str) -> String {
    p.split('/')
        .filter(|s| !s.is_empty())
        .last()
        .unwrap_or(p)
        .to_string()
}

struct Shaped {
    messages: Vec<Value>,
    model: Option<String>,
    totals: (i64, i64, i64, i64),
    first_ts: Option<String>,
    last_ts: Option<String>,
}
fn shape_session(recs: &[Value]) -> Shaped {
    let mut messages = vec![];
    let (mut tin, mut tout, mut tcr, mut turns) = (0i64, 0i64, 0i64, 0i64);
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
            turns += 1;
        }
        messages.push(lm);
    }
    Shaped {
        messages,
        model,
        totals: (tin, tout, tcr, turns),
        first_ts,
        last_ts,
    }
}

fn read_subagents(file: &Path) -> Value {
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
    let mut by_tool = serde_json::Map::new();
    for ent in entries.flatten() {
        let name = ent.file_name().to_string_lossy().into_owned();
        if !(name.starts_with("agent-") && name.ends_with(".jsonl")) {
            continue;
        }
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
        let recs = parse_jsonl(&ent.path());
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
                "totals": { "in": shaped.totals.0, "out": shaped.totals.1, "cacheRead": shaped.totals.2, "turns": shaped.totals.3 },
                "messages": shaped.messages,
            }),
        );
    }
    Value::Object(by_tool)
}

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
                        "meta": false,
                    });
                    let o = out.as_object_mut().unwrap();
                    if let Some(md) = msg.get("modelActual") {
                        o.insert("model".into(), md.clone());
                    }
                    if let Some(u) = msg.get("usage") {
                        o.insert(
                            "usage".into(),
                            json!({
                                "in": u.get("inputTokens").and_then(|v| v.as_i64()).unwrap_or(0),
                                "out": u.get("outputTokens").and_then(|v| v.as_i64()).unwrap_or(0),
                                "cacheRead": u.get("cacheRead").and_then(|v| v.as_i64()).unwrap_or(0),
                                "cacheCreation": u.get("cacheCreation").and_then(|v| v.as_i64()).unwrap_or(0),
                            }),
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
    // Foreign sources first — container-shape routing (one of them is SQLite, not jsonl).
    match crate::history::foreign_kind(path) {
        Some(crate::history::Foreign::Grok) => {
            let recs = parse_jsonl(path);
            return build_from_session(crate::grok::session_from_recs(file, &recs), "Grok");
        }
        Some(crate::history::Foreign::Copilot) => {
            let recs = parse_jsonl(path);
            return build_from_session(crate::copilot::session_from_recs(file, &recs), "Copilot");
        }
        Some(crate::history::Foreign::Antigravity) => {
            return build_from_session(crate::antigravity::session_from(file), "Antigravity");
        }
        None => {}
    }
    let recs = parse_jsonl(path);
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
            "subagentCount": subagents.as_object().map(|o| o.len()).unwrap_or(0),
            "firstTs": s.first_ts, "lastTs": s.last_ts,
        },
        "messages": s.messages,
        "subagents": subagents,
    })
}

pub fn html_from_data(data: &Value) -> String {
    let json = serde_json::to_string(data)
        .unwrap_or_default()
        .replace('<', "\\u003c");
    // Tab title uses the project name (already public via the export's filename), NOT the
    // conversation title: Clarity reports document.title as page metadata that masking can't
    // reach, and the conversation title is first-message text. The full title still renders
    // in the viewer header, inside the Clarity-masked #app.
    let title = data
        .get("meta")
        .and_then(|m| m.get("project"))
        .and_then(|v| v.as_str())
        .unwrap_or("Conversation")
        .replace(['<', '>'], "");
    // The exported viewer is a static file opened in a plain browser (no app CSP). A nonce-based
    // CSP lets ONLY these four generator-emitted <script> blocks run: an injected inline handler
    // (e.g. an <img onerror> from a crafted image data-URL) or a `javascript:` link in a message
    // carries no nonce, so the browser refuses to execute it. The clarity.ms origins additionally
    // allow the Clarity analytics tag the runtime injects. img-src data: keeps inline images;
    // style-src 'unsafe-inline' keeps the embedded skin. Nonce is static (a local file has no
    // replay threat model — it only separates our scripts from attacker-injected markup).
    let csp = "default-src 'none'; script-src 'nonce-ccbudexport' https://www.clarity.ms https://*.clarity.ms; connect-src https://*.clarity.ms https://c.bing.com; style-src 'unsafe-inline'; img-src data:; base-uri 'none'";
    format!(
        "<!doctype html><html lang=\"zh\" data-theme=\"light\"><head><meta charset=\"utf-8\">\
<meta http-equiv=\"Content-Security-Policy\" content=\"{csp}\">\
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
<title>{title} · CC Buddy</title>\
<style>{skin}\n{hljscss}</style>\
</head><body><div id=\"app\" data-clarity-mask=\"true\"></div>\
<script nonce=\"ccbudexport\">{marked}</script>\
<script nonce=\"ccbudexport\">{hljs}</script>\
<script nonce=\"ccbudexport\">window.__CONV__={json};window.__CCBUD_VERSION__=\"{version}\";</script>\
<script nonce=\"ccbudexport\">{runtime}</script>\
</body></html>",
        csp = csp,
        title = title,
        skin = SKIN,
        hljscss = HLJS_CSS,
        marked = MARKED,
        hljs = HLJS,
        json = json,
        version = env!("CARGO_PKG_VERSION"),
        runtime = RUNTIME,
    )
}

pub fn build_export_html(file: &str) -> String {
    html_from_data(&build_data(file))
}

// ---- export filename ----
// Default export base name: `<project>-<convStart>-<exportedAt>`, both timestamps as YYMMDDHHmm
// (local time). Earlier exports used collision-prone names (UUID-only JSONL or first-message HTML);
// this keeps bulk exports stable and sortable.

// path/url-hostile chars + whitespace runs collapse to a single `_`; leading/trailing `_ . -` are
// trimmed; result capped at 60 chars.
fn sanitize_name(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut prev_underscore = false;
    for ch in s.chars() {
        let bad = matches!(
            ch,
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\n' | '\r'
        ) || ch.is_whitespace();
        if bad {
            if !prev_underscore {
                out.push('_');
                prev_underscore = true;
            }
        } else {
            out.push(ch);
            prev_underscore = false;
        }
    }
    out.trim_matches(|c| c == '_' || c == '.' || c == '-')
        .chars()
        .take(60)
        .collect()
}

// Parse an ISO-8601 `ts` and render it as YYMMDDHHmm in local time (matches `new Date(ts)` + the
// Date's local getters used by the original).
fn fmt_ts_local(ts: &str) -> Option<String> {
    chrono::DateTime::parse_from_rfc3339(ts).ok().map(|dt| {
        dt.with_timezone(&chrono::Local)
            .format("%y%m%d%H%M")
            .to_string()
    })
}

// Derive the base name from already-built export `data` (avoids re-parsing for the HTML path).
pub fn export_base_name_from_data(data: &Value) -> String {
    let meta = data.get("meta");
    let project = meta
        .and_then(|m| m.get("project"))
        .and_then(|v| v.as_str())
        .map(sanitize_name)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "conversation".to_string());
    let conv_part = meta
        .and_then(|m| m.get("firstTs"))
        .and_then(|v| v.as_str())
        .and_then(fmt_ts_local)
        .unwrap_or_else(|| "unknown".to_string());
    let exported_at = chrono::Local::now().format("%y%m%d%H%M").to_string();
    format!("{}-{}-{}", project, conv_part, exported_at)
}

// Build + shape the file, then derive the base name (JSONL export path, which has no `data` yet).
pub fn export_base_name(file: &str) -> String {
    export_base_name_from_data(&build_data(file))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn qoder_fixture(name: &str) -> (PathBuf, PathBuf) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "ccbud-exporthtml-{name}-{}-{nonce}",
            std::process::id()
        ));
        let file = root
            .join(".qoder")
            .join("projects")
            .join("-work-project")
            .join("session.jsonl");
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        (root, file)
    }

    fn write_jsonl(path: &Path, records: &[Value]) {
        let raw = records
            .iter()
            .map(|record| serde_json::to_string(record).unwrap())
            .collect::<Vec<_>>()
            .join("\n");
        fs::write(path, format!("{raw}\n")).unwrap();
    }

    fn streamed_assistant_records() -> Vec<Value> {
        vec![
            json!({
                "type": "assistant",
                "uuid": "wrap-1",
                "message": {
                    "id": "msg-1",
                    "role": "assistant",
                    "model": "",
                    "content": [{ "type": "thinking", "thinking": "plan" }],
                    "stop_reason": null,
                },
            }),
            json!({
                "type": "assistant",
                "uuid": "wrap-2",
                "message": {
                    "id": "msg-1",
                    "role": "assistant",
                    "model": "ultimate",
                    "content": [{ "type": "redacted_thinking", "data": "opaque" }],
                    "stop_reason": null,
                },
            }),
            json!({
                "type": "assistant",
                "uuid": "wrap-3",
                "message": {
                    "id": "msg-1",
                    "role": "assistant",
                    "model": "ultimate",
                    "content": [{
                        "type": "tool_use",
                        "id": "tool-1",
                        "name": "Read",
                        "input": { "file_path": "/work/a" },
                    }],
                    "usage": { "input_tokens": 7, "output_tokens": 3 },
                    "stop_reason": "tool_use",
                },
            }),
        ]
    }

    #[test]
    fn qoder_jsonl_normalizes_streamed_assistant_records() {
        let (root, file) = qoder_fixture("normalize");
        write_jsonl(&file, &streamed_assistant_records());

        let records = parse_jsonl(&file);
        assert_eq!(records.len(), 1);
        assert_eq!(
            records[0].get("uuid").and_then(Value::as_str),
            Some("wrap-1")
        );
        let message = records[0].get("message").unwrap();
        assert_eq!(
            message.get("model").and_then(Value::as_str),
            Some("ultimate")
        );
        assert_eq!(
            message.get("stop_reason").and_then(Value::as_str),
            Some("tool_use")
        );
        assert_eq!(
            message
                .get("usage")
                .and_then(|usage| usage.get("input_tokens"))
                .and_then(Value::as_i64),
            Some(7)
        );
        let content = message.get("content").and_then(Value::as_array).unwrap();
        assert_eq!(content.len(), 2);
        assert_eq!(
            content[0].get("type").and_then(Value::as_str),
            Some("thinking")
        );
        assert_eq!(
            content[1].get("type").and_then(Value::as_str),
            Some("tool_use")
        );

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn ordinary_jsonl_keeps_streamed_records_unchanged() {
        let (root, _) = qoder_fixture("ordinary");
        let file = root.join("ordinary.jsonl");
        write_jsonl(&file, &streamed_assistant_records());

        let records = parse_jsonl(&file);
        assert_eq!(records.len(), 3);

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn qoder_export_uses_record_metadata_and_reads_subagent_meta() {
        let (root, file) = qoder_fixture("metadata");
        write_jsonl(
            &file,
            &[
                json!({
                    "type": "workspace-directories",
                    "sessionId": "session",
                    "directories": ["/work/project"],
                }),
                json!({
                    "type": "runtime-config",
                    "sessionId": "session",
                    "model": "ultimate",
                }),
                json!({
                    "type": "ai-title",
                    "sessionId": "session",
                    "aiTitle": "Inline Qoder title",
                }),
                json!({
                    "type": "user",
                    "uuid": "user-1",
                    "timestamp": "2026-08-04T08:00:00Z",
                    "message": { "role": "user", "content": "User fallback title" },
                }),
                json!({
                    "type": "assistant",
                    "uuid": "assistant-1",
                    "timestamp": "2026-08-04T08:01:00Z",
                    "message": {
                        "id": "answer-1",
                        "role": "assistant",
                        "model": "message-model",
                        "content": [{ "type": "text", "text": "Done" }],
                        "usage": { "input_tokens": 2, "output_tokens": 1 },
                        "stop_reason": "end_turn",
                    },
                }),
            ],
        );
        fs::write(
            file.parent().unwrap().join("session-session.json"),
            r#"{"title":"stale companion title","working_dir":"/stale/path"}"#,
        )
        .unwrap();

        let subagent_dir = file.parent().unwrap().join("session").join("subagents");
        fs::create_dir_all(&subagent_dir).unwrap();
        write_jsonl(
            &subagent_dir.join("agent-a.jsonl"),
            &[
                json!({
                    "type": "user",
                    "uuid": "sub-user",
                    "message": { "role": "user", "content": "Investigate" },
                }),
                json!({
                    "type": "assistant",
                    "uuid": "sub-assistant",
                    "message": {
                        "id": "sub-answer",
                        "role": "assistant",
                        "model": "ultimate",
                        "content": [{ "type": "text", "text": "Found it" }],
                    },
                }),
            ],
        );
        fs::write(
            subagent_dir.join("agent-a.meta.json"),
            r#"{"toolUseId":"tool-a","agentType":"Explore","description":"trace"}"#,
        )
        .unwrap();

        let data = build_data(&file.to_string_lossy());
        let meta = data.get("meta").unwrap();
        assert_eq!(meta.get("assistant").and_then(Value::as_str), Some("Qoder"));
        assert_eq!(
            meta.get("title").and_then(Value::as_str),
            Some("Inline Qoder title")
        );
        assert_eq!(
            meta.get("cwd").and_then(Value::as_str),
            Some("/work/project")
        );
        assert_eq!(meta.get("project").and_then(Value::as_str), Some("project"));
        assert_eq!(meta.get("model").and_then(Value::as_str), Some("ultimate"));
        assert_eq!(meta.get("subagentCount").and_then(Value::as_u64), Some(1));
        let subagent = data
            .get("subagents")
            .and_then(|subagents| subagents.get("tool-a"))
            .unwrap();
        assert_eq!(
            subagent.get("type").and_then(Value::as_str),
            Some("Explore")
        );
        assert_eq!(
            subagent.get("description").and_then(Value::as_str),
            Some("trace")
        );
        assert_eq!(subagent.get("count").and_then(Value::as_u64), Some(2));

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn qoder_export_falls_back_to_top_level_cwd_and_assistant_model() {
        let (root, file) = qoder_fixture("metadata-fallback");
        write_jsonl(
            &file,
            &[
                json!({
                    "type": "user",
                    "uuid": "user-1",
                    "sessionId": "session",
                    "cwd": "/legacy/work",
                    "message": { "role": "user", "content": "Fallback title" },
                }),
                json!({
                    "type": "assistant",
                    "uuid": "assistant-1",
                    "message": {
                        "id": "answer-1",
                        "role": "assistant",
                        "model": "legacy-model",
                        "content": [{ "type": "text", "text": "Done" }],
                    },
                }),
            ],
        );

        let data = build_data(&file.to_string_lossy());
        let meta = data.get("meta").unwrap();
        assert_eq!(
            meta.get("cwd").and_then(Value::as_str),
            Some("/legacy/work")
        );
        assert_eq!(meta.get("project").and_then(Value::as_str), Some("work"));
        assert_eq!(
            meta.get("model").and_then(Value::as_str),
            Some("legacy-model")
        );

        fs::remove_dir_all(root).unwrap();
    }
}
