use serde_json::Value;

use super::monitor::UsageAcc;

fn model_rewrite_re() -> &'static regex::Regex {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r#"("model"\s*:\s*")[^"]*(")"#).unwrap())
}

fn absorb_usage_sse(obj: &Value, usage: &mut UsageAcc) {
    match obj.get("type").and_then(|v| v.as_str()) {
        Some("message_start") => {
            if let Some(u) = obj.get("message").and_then(|m| m.get("usage")) {
                usage.input += u.get("input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                usage.cache_read += u.get("cache_read_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                usage.cache_creation += u.get("cache_creation_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                usage.saw = true;
            }
        }
        Some("message_delta") => {
            if let Some(o) = obj.get("usage").and_then(|u| u.get("output_tokens")).and_then(|v| v.as_i64()) {
                usage.output = o;
                usage.saw = true;
            }
        }
        _ => {}
    }
}

pub(super) fn process_sse_line(line: &str, rewrite_model: Option<&str>, usage: &mut UsageAcc) -> String {
    if line.contains("\"usage\"") {
        if let Some(i) = line.find('{') {
            if let Ok(obj) = serde_json::from_str::<Value>(line[i..].trim()) {
                absorb_usage_sse(&obj, usage);
            }
        }
    }
    if let Some(m) = rewrite_model {
        if line.contains("\"model\"") {
            return model_rewrite_re()
                .replace_all(line, |caps: &regex::Captures| format!("{}{}{}", &caps[1], m, &caps[2]))
                .into_owned();
        }
    }
    line.to_string()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ResponsesTerminalKind {
    Completed,
    Incomplete,
    Failed,
}

impl ResponsesTerminalKind {
    pub(super) fn is_resumable(self) -> bool {
        matches!(self, Self::Completed | Self::Incomplete)
    }
}

#[derive(Debug, Clone)]
pub(super) struct ResponsesTerminal {
    pub(super) kind: ResponsesTerminalKind,
    pub(super) response: Option<Value>,
}

pub(super) fn responses_terminal_event(sse: &str) -> Option<ResponsesTerminal> {
    sse.lines().rev().find_map(|line| {
        let payload = line.trim().strip_prefix("data:")?.trim();
        let event: Value = serde_json::from_str(payload).ok()?;
        let kind = match event.get("type").and_then(Value::as_str)? {
            "response.completed" => ResponsesTerminalKind::Completed,
            "response.incomplete" => ResponsesTerminalKind::Incomplete,
            "response.failed" => ResponsesTerminalKind::Failed,
            _ => return None,
        };
        Some(ResponsesTerminal {
            kind,
            response: event.get("response").cloned(),
        })
    })
}

pub(super) fn responses_terminal_object(response: &Value) -> Option<ResponsesTerminal> {
    let kind = match response.get("status").and_then(Value::as_str)? {
        "completed" => ResponsesTerminalKind::Completed,
        "incomplete" => ResponsesTerminalKind::Incomplete,
        "failed" => ResponsesTerminalKind::Failed,
        _ => return None,
    };
    Some(ResponsesTerminal {
        kind,
        response: Some(response.clone()),
    })
}

pub(super) fn is_responses_compact_path(path: &str) -> bool {
    matches!(
        path.trim_end_matches('/'),
        "/responses/compact" | "/v1/responses/compact"
    )
}
