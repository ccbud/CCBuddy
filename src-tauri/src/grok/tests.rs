use super::meta::{percent_decode, session_uuid};
use super::normalize::normalize;
use super::roots::{is_cwd_dir_name, looks_grok_path};
use serde_json::{json, Value};
use std::path::Path;

fn recs() -> Vec<Value> {
    vec![
        json!({ "type": "system", "content": "You are Grok…" }),
        json!({ "type": "user", "content": [{ "type": "text", "text": "<user_info>\nOS: macos\n</user_info>\n\n<git_status>\nclean\n</git_status>\n" }] }),
        json!({ "type": "user", "content": [
            { "type": "text", "text": "<user_query>\n修复登录 bug\n</user_query>" },
            { "type": "image", "url": "data:image/png;base64,QUJD" }
        ] }),
        json!({ "type": "reasoning", "id": "rs_1", "summary": [{ "type": "summary_text", "text": "Scanning the repo" }] }),
        json!({ "type": "assistant", "content": "先看下目录。", "tool_calls": [
            { "id": "call-1", "name": "run_terminal_command", "arguments": "{\"command\":\"ls\",\"description\":\"List files\"}" },
            { "id": "call-2", "name": "read_file", "arguments": "{\"target_file\":\"src/app.js\"}" }
        ] }),
        json!({ "type": "tool_result", "tool_call_id": "call-1", "content": "a.txt\nb.txt" }),
        json!({ "type": "tool_result", "tool_call_id": "call-2", "content": "console.log(1)", "images": [{ "type": "image", "url": "data:image/png;base64,REVG" }] }),
    ]
}

fn summary() -> Value {
    json!({
        "info": { "id": "0199-aaaa", "cwd": "/tmp/proj" },
        "generated_title": "Fix login bug",
        "created_at": "2026-06-18T06:27:07.777809Z",
        "last_active_at": "2026-06-18T06:57:37.242478Z",
        "current_model_id": "grok-build",
        "head_branch": "main",
    })
}

#[test]
fn normalizes_conversation() {
    let s = summary();
    let n = normalize(&recs(), Some(&s));
    // harness wrapper user turn dropped; real turns: user, thinking, assistant+tools, 2 results
    assert_eq!(n.messages.len(), 5);
    assert_eq!(n.messages[0]["role"], "user");
    assert_eq!(n.messages[0]["content"][0]["text"], "修复登录 bug");
    assert_eq!(n.messages[0]["content"][1]["type"], "image");
    assert_eq!(n.messages[1]["content"][0]["type"], "thinking");
    let a = &n.messages[2];
    assert_eq!(a["content"][0]["text"], "先看下目录。");
    assert_eq!(a["content"][1]["name"], "Bash");
    assert_eq!(a["content"][1]["input"]["command"], "ls");
    assert_eq!(a["content"][2]["name"], "Read");
    assert_eq!(a["content"][2]["input"]["file_path"], "src/app.js");
    assert_eq!(n.messages[3]["content"][0]["tool_use_id"], "call-1");
    // image-carrying result becomes a block array
    assert_eq!(n.messages[4]["content"][0]["content"][1]["type"], "image");
    assert_eq!(n.model.as_deref(), Some("grok-build"));
    assert_eq!(n.cwd.as_deref(), Some("/tmp/proj"));
}

#[test]
fn detects_cwd_dirs_and_paths() {
    assert!(is_cwd_dir_name("%2FUsers%2Fme%2Fcode"));
    assert!(is_cwd_dir_name("%2fusers%2fme"));
    assert!(!is_cwd_dir_name("2026"));
    assert_eq!(percent_decode("%2FUsers%2Fme"), "/Users/me");
    let p = Path::new("/x/sessions/%2FUsers%2Fme/0199-aaaa/chat_history.jsonl");
    assert!(looks_grok_path(p));
    assert!(!looks_grok_path(Path::new("/x/sessions/2026/01/01/rollout-1.jsonl")));
    assert_eq!(session_uuid(p), "0199-aaaa");
}
