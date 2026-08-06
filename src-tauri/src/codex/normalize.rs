// Rollout -> renderer message model (split from codex.rs). The response_item arm lives in
// items.rs (see on_response_item) to keep both files under the split's size cap.

use crate::history::Norm;
use serde_json::{json, Value};

use super::items::on_response_item;
use super::records::{canonical_thread_meta, split_line};

/// Normalize parsed rollout records into the renderer's message model.
pub fn normalize(recs: &[Value]) -> Norm {
    let mut messages: Vec<Value> = vec![];
    let (mut tin, mut tout, mut tcr, mut turns) = (0i64, 0i64, 0i64, 0i64);
    let mut model: Option<String> = None;
    let mut cwd: Option<String> = None;
    let mut session_id: Option<String> = None;
    let mut thread_id: Option<String> = None;
    let mut parent_thread_id: Option<String> = None;
    let mut forked_from_id: Option<String> = None;
    let mut is_subagent = false;
    let mut agent_path: Option<String> = None;
    let mut agent_nickname: Option<String> = None;
    let mut agent_role: Option<String> = None;
    let mut agent_depth: Option<i64> = None;
    let mut saw_session_meta = false;
    let mut git_branch: Option<String> = None;
    let mut version: Option<String> = None;

    for rec in recs {
        let (ty, p, ts) = split_line(rec);
        let with_ts = |mut m: Value| {
            if let Some(t) = ts {
                m["ts"] = json!(t);
            }
            m
        };
        match ty {
            "session_meta" => {
                if !saw_session_meta {
                    saw_session_meta = true;
                    let identity = canonical_thread_meta(p);
                    thread_id = identity.thread_id;
                    session_id = identity.root_session_id;
                    parent_thread_id = identity.parent_thread_id;
                    forked_from_id = identity.forked_from_id;
                    is_subagent = identity.is_subagent;
                    agent_path = identity.agent_path;
                    agent_nickname = identity.agent_nickname;
                    agent_role = identity.agent_role;
                    agent_depth = identity.agent_depth;
                }
                let sid = p
                    .get("session_id")
                    .or_else(|| p.get("id"))
                    .and_then(|v| v.as_str());
                if session_id.is_none() {
                    session_id = sid.map(|s| s.to_string());
                }
                if cwd.is_none() {
                    cwd = p.get("cwd").and_then(|v| v.as_str()).map(|s| s.to_string());
                }
                if version.is_none() {
                    version = p.get("cli_version").and_then(|v| v.as_str()).map(|s| s.to_string());
                }
                if git_branch.is_none() {
                    git_branch = p
                        .get("git")
                        .and_then(|g| g.get("branch"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string());
                }
            }
            "turn_context" => {
                if let Some(m) = p.get("model").and_then(|v| v.as_str()) {
                    model = Some(m.to_string());
                }
                if cwd.is_none() {
                    cwd = p.get("cwd").and_then(|v| v.as_str()).map(|s| s.to_string());
                }
            }
            "compacted" => {
                let text = p.get("message").and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
                if !text.is_empty() {
                    messages.push(with_ts(json!({ "role": "user", "content": [{ "type": "text", "text": text }] })));
                }
            }
            "event_msg" => match p.get("type").and_then(|v| v.as_str()).unwrap_or("") {
                "token_count" => {
                    let u = p.get("info").and_then(|i| i.get("last_token_usage"));
                    if let Some(u) = u {
                        let input = u.get("input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                        let cached = u.get("cached_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                        let output = u.get("output_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                        if input + cached + output > 0 {
                            let usage = json!({
                                "inputTokens": (input - cached).max(0),
                                "outputTokens": output,
                                "cacheRead": cached,
                                "cacheCreation": 0,
                            });
                            tin += (input - cached).max(0);
                            tout += output;
                            tcr += cached;
                            turns += 1;
                            // Per-turn usage rides the turn's last assistant message (codex emits
                            // one token_count per model turn).
                            if let Some(m) = messages
                                .iter_mut()
                                .rev()
                                .find(|m| m.get("role").and_then(|r| r.as_str()) == Some("assistant") && m.get("usage").is_none())
                            {
                                m["usage"] = usage;
                            }
                        }
                    }
                }
                "turn_aborted" => {
                    messages.push(with_ts(json!({
                        "role": "user",
                        "content": [{ "type": "text", "text": "[Request interrupted by user]" }],
                    })));
                }
                _ => {}
            },
            "response_item" => on_response_item(p, ts, &model, &mut messages),
            _ => {}
        }
    }

    let first_ts = messages
        .first()
        .and_then(|m| m.get("ts"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let last_ts = messages
        .last()
        .and_then(|m| m.get("ts"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    Norm {
        messages,
        totals: json!({ "in": tin, "out": tout, "cacheRead": tcr, "cacheCreation": 0, "turns": turns }),
        model,
        first_ts,
        last_ts,
        cwd,
        session_id,
        thread_id,
        parent_thread_id,
        forked_from_id,
        is_subagent,
        agent_path,
        agent_nickname,
        agent_role,
        agent_depth,
        git_branch,
        version,
    }
}
