// Rollout record classification: line envelope split, canonical thread identity, meta/skill
// user-turn detection, and head ids (split from codex.rs).

use serde_json::{json, Value};

/// (type, payload, timestamp) of a rollout line, tolerating the old envelope-less format.
pub(super) fn split_line(rec: &Value) -> (&str, &Value, Option<&str>) {
    let ts = rec.get("timestamp").and_then(|v| v.as_str());
    let t = rec.get("type").and_then(|v| v.as_str()).unwrap_or("");
    if let Some(p) = rec.get("payload") {
        return (t, p, ts);
    }
    match t {
        "message" | "function_call" | "function_call_output" | "reasoning" | "local_shell_call"
        | "custom_tool_call" | "custom_tool_call_output" | "web_search_call" => ("response_item", rec, ts),
        // old first line: bare SessionMeta {id, timestamp, instructions, cwd?, git?}
        "" if rec.get("id").is_some() && rec.get("timestamp").is_some() => ("session_meta", rec, ts),
        _ => (t, rec, ts),
    }
}

#[derive(Default)]
pub(super) struct CanonicalThreadMeta {
    pub(super) thread_id: Option<String>,
    pub(super) root_session_id: Option<String>,
    pub(super) parent_thread_id: Option<String>,
    pub(super) forked_from_id: Option<String>,
    pub(super) is_subagent: bool,
    pub(super) agent_path: Option<String>,
    pub(super) agent_nickname: Option<String>,
    pub(super) agent_role: Option<String>,
    pub(super) agent_depth: Option<i64>,
}

// The first SessionMeta is canonical for the physical rollout. Subagent/fork rollouts can copy
// ancestor SessionMeta records behind it, and every thread in that tree intentionally shares the
// same session_id. The unique thread key is the first meta's id.
pub(super) fn canonical_thread_meta(payload: &Value) -> CanonicalThreadMeta {
    let subagent = payload
        .get("source")
        .and_then(|source| source.get("subagent").or_else(|| source.get("sub_agent")))
        .or_else(|| {
            payload
                .get("thread_source")
                .and_then(|source| source.get("subagent").or_else(|| source.get("sub_agent")))
        });
    let detail = subagent.and_then(|source| {
        ["thread_spawn", "review", "compact", "other"]
            .iter()
            .find_map(|key| source.get(*key).filter(|value| value.is_object()))
            .or_else(|| source.as_object().and_then(|object| object.values().find(|value| value.is_object())))
    });
    let string = |value: Option<&Value>| {
        value
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_string)
    };
    let thread_id = string(
        payload
            .get("id")
            .or_else(|| payload.get("thread_id")),
    );
    let root_session_id = string(payload.get("session_id")).or_else(|| thread_id.clone());
    let parent_thread_id = string(
        payload
            .get("parent_thread_id")
            .or_else(|| detail.and_then(|value| value.get("parent_thread_id"))),
    );
    let is_subagent = subagent.is_some()
        || payload.get("thread_source").and_then(Value::as_str) == Some("subagent")
        || payload
            .get("agent_path")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty())
        || payload
            .get("agent_nickname")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty())
        || (parent_thread_id.is_some() && thread_id != root_session_id);
    CanonicalThreadMeta {
        thread_id,
        root_session_id,
        parent_thread_id,
        forked_from_id: string(payload.get("forked_from_id")),
        is_subagent,
        // Current Codex stores the canonical Agent identity on SessionMeta itself. Older
        // rollouts only carried it inside source.subagent.<kind>, so keep that as a fallback.
        agent_path: string(
            payload
                .get("agent_path")
                .or_else(|| detail.and_then(|value| value.get("agent_path"))),
        ),
        agent_nickname: string(
            payload
                .get("agent_nickname")
                .or_else(|| detail.and_then(|value| value.get("agent_nickname"))),
        ),
        agent_role: string(
            payload
                .get("agent_role")
                .or_else(|| payload.get("agent_type"))
                .or_else(|| detail.and_then(|value| value.get("agent_role")))
                .or_else(|| detail.and_then(|value| value.get("agent_type"))),
        ),
        agent_depth: detail.and_then(|value| value.get("depth")).and_then(|value| value.as_i64()),
    }
}

/// Harness-injected user turns (environment/permissions/instructions wrappers) that aren't
/// human prose — hidden from the timeline, exactly like Claude's isMeta records.
pub(super) fn is_meta_user_text(t: &str) -> bool {
    let t = t.trim_start();
    ["<environment_context>", "<user_instructions>", "<permissions", "<ide_", "<turn_context", "<AGENTS", "<workspace_"]
        .iter()
        .any(|p| t.starts_with(p))
}

// The workspace AGENTS bootstrap is user-role transport data. Keep it visible in the transcript
// (the renderer formats it as Markdown), but mark it as metadata so it cannot become the title.
pub(super) fn is_agents_bootstrap(t: &str) -> bool {
    let source = t.trim_start();
    let Some(heading) = source.strip_prefix('#') else { return false; };
    let heading = heading.trim_start().to_ascii_lowercase();
    heading.starts_with("agents.md instructions for ")
        && heading.contains("<instructions")
        && heading.contains("</instructions>")
}

// Codex serializes a loaded Skill as a synthetic user turn. Keep the snapshot embedded in the
// rollout rather than reading the current SKILL.md from disk: historical sessions must show the
// exact instructions that were loaded at the time. Anchoring the whole envelope leaves quoted
// <skill> markup in normal user prose untouched.
pub(super) fn skill_load_block(t: &str) -> Option<Value> {
    static SKILL_ENVELOPE_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re = SKILL_ENVELOPE_RE.get_or_init(|| {
        regex::Regex::new(
            r"(?is)^\s*<skill>\s*<name>(.*?)</name>\s*<path>(.*?)</path>(.*)</skill>\s*$",
        )
        .unwrap()
    });
    let captures = re.captures(t)?;
    let name = captures.get(1)?.as_str().trim();
    let path = captures.get(2)?.as_str().trim();
    if name.is_empty() || path.is_empty() {
        return None;
    }
    let snapshot = captures.get(3)?.as_str();
    Some(json!({
        "type": "skill_load",
        "name": name,
        "path": path,
        "snapshot": snapshot,
    }))
}

/// (cwd, canonical thread id) from a Codex head — used to name an imported store copy.
pub fn head_ids(recs: &[Value]) -> (Option<String>, Option<String>) {
    for rec in recs {
        let (ty, p, _) = split_line(rec);
        if ty == "session_meta" {
            let cwd = p.get("cwd").and_then(|v| v.as_str()).map(|s| s.to_string());
            let sid = p
                // Every subagent in a tree shares session_id. The FIRST SessionMeta.id is the
                // unique rollout key; using session_id makes sibling imports collide.
                .get("id")
                .or_else(|| p.get("thread_id"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            return (cwd, sid);
        }
    }
    (None, None)
}
