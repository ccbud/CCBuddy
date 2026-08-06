// Codex tool call -> renderer tool card mapping, and tool output shaping (split from codex.rs).

use serde_json::{json, Value};

use super::exec::exec_text_err;

/// argv → display command: unwrap the ["bash","-lc", script] convention, else shell-ish join.
pub(super) fn join_argv(cmd: &Value) -> String {
    if let Some(s) = cmd.as_str() {
        return s.to_string();
    }
    let arr = match cmd.as_array() {
        Some(a) => a,
        None => return String::new(),
    };
    let parts: Vec<String> = arr.iter().map(|x| x.as_str().unwrap_or_default().to_string()).collect();
    if parts.len() == 3
        && ["bash", "sh", "zsh", "dash"].contains(&parts[0].as_str())
        && ["-lc", "-c"].contains(&parts[1].as_str())
    {
        return parts[2].clone();
    }
    parts
        .iter()
        .map(|p| {
            if p.is_empty() || p.chars().any(|c| c.is_whitespace() || c == '"' || c == '\'') {
                format!("{:?}", p) // debug-quote args with spaces/quotes
            } else {
                p.clone()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Codex tool name + parsed arguments → (renderer tool name, renderer input).
pub(super) fn map_tool(name: &str, args: &Value) -> (String, Value) {
    let s = |k: &str| args.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
    match name {
        "shell" | "local_shell" | "container.exec" => {
            let mut input = json!({ "command": join_argv(args.get("command").unwrap_or(&Value::Null)) });
            let desc = if !s("justification").is_empty() { s("justification") } else { s("workdir") };
            if !desc.is_empty() {
                input["description"] = json!(desc);
            }
            ("Bash".into(), input)
        }
        "shell_command" => ("Bash".into(), json!({ "command": s("command") })),
        "exec_command" => {
            let cmd = if !s("cmd").is_empty() { s("cmd") } else { s("command") };
            ("Bash".into(), json!({ "command": cmd }))
        }
        "apply_patch" => {
            let patch = if !s("input").is_empty() { s("input") } else { s("patch") };
            ("ApplyPatch".into(), json!({ "patch": patch }))
        }
        "update_plan" => {
            let todos: Vec<Value> = args
                .get("plan")
                .and_then(|p| p.as_array())
                .map(|a| {
                    a.iter()
                        .map(|st| {
                            json!({
                                "content": st.get("step").and_then(|v| v.as_str()).unwrap_or(""),
                                "status": st.get("status").and_then(|v| v.as_str()).unwrap_or("pending"),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            ("TodoWrite".into(), json!({ "todos": todos }))
        }
        "view_image" => ("Read".into(), json!({ "file_path": s("path") })),
        "web_search" => ("WebSearch".into(), json!({ "query": s("query") })),
        _ => (
            name.to_string(),
            if args.is_object() { args.clone() } else { json!({}) },
        ),
    }
}

/// Tool output payload → (display text, is_error). Unwraps codex's JSON-wrapped shell output
/// ({"output","metadata":{exit_code}}) and reads exec_command's "exited with code N" header.
pub(super) fn shape_output(out: &Value) -> (String, bool) {
    // structured payload: { content, success? }
    if out.is_object() {
        let text = out
            .get("content")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| serde_json::to_string_pretty(out).unwrap_or_default());
        let err = out.get("success").and_then(|v| v.as_bool()) == Some(false);
        return (text, err);
    }
    let s = out.as_str().unwrap_or("").to_string();
    if let Ok(v) = serde_json::from_str::<Value>(&s) {
        if v.is_object() {
            if let Some(o) = v.get("output").and_then(|x| x.as_str()) {
                let code = v
                    .get("metadata")
                    .and_then(|m| m.get("exit_code"))
                    .and_then(|c| c.as_i64())
                    .unwrap_or(0);
                return (o.to_string(), code != 0);
            }
            if let Some(c) = v.get("content").and_then(|x| x.as_str()) {
                let err = v.get("success").and_then(|x| x.as_bool()) == Some(false);
                return (c.to_string(), err);
            }
        }
    }
    // code-mode runner header (older builds wrote it as a plain string): "Exit code: N…" /
    // "Script failed…"
    if exec_text_err(&s) {
        return (s, true);
    }
    // exec_command header: "…\nProcess exited with code N\n…" near the top
    let head: String = s.chars().take(240).collect();
    if let Some(pos) = head.find("exited with code ") {
        let digits: String = head[pos + "exited with code ".len()..]
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect();
        if let Ok(code) = digits.parse::<i64>() {
            return (s, code != 0);
        }
    }
    (s, false)
}
