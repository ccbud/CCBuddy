use super::meta::session_uuid;
use super::normalize::normalize;
use super::roots::looks_copilot_path;
use serde_json::{json, Value};
use std::path::Path;

fn ev(ts: &str, ty: &str, data: Value) -> Value {
    json!({ "type": ty, "data": data, "id": "e", "timestamp": ts, "parentId": null })
}

fn recs() -> Vec<Value> {
    vec![
        ev("2026-07-12T07:26:54.363Z", "session.start", json!({
            "sessionId": "d34d-1111", "copilotVersion": "1.0.70",
            "context": { "cwd": "/tmp/shhh", "gitRoot": "/tmp/shhh", "branch": "main" }
        })),
        ev("2026-07-12T07:27:00.685Z", "session.model_change", json!({ "newModel": "gpt-5.6" })),
        ev("2026-07-12T07:27:05.000Z", "system.message", json!({ "role": "system", "content": "You are Copilot" })),
        ev("2026-07-12T07:27:14.000Z", "user.message", json!({ "content": "修沙盒问题", "attachments": [] })),
        ev("2026-07-12T07:27:15.000Z", "assistant.message", json!({
            "messageId": "m1", "model": "gpt-5.6", "content": "我先搜一下。",
            "toolRequests": [
                { "toolCallId": "call_A", "name": "rg", "arguments": { "pattern": "sandbox", "paths": ".", "glob": "*.plist" } },
                { "toolCallId": "call_B", "name": "bash", "arguments": { "command": "ls", "description": "List", "mode": "sync", "sessionId": "main" } }
            ]
        })),
        ev("2026-07-12T07:27:16.000Z", "tool.execution_start", json!({ "toolCallId": "call_A", "toolName": "rg" })),
        ev("2026-07-12T07:27:17.000Z", "tool.execution_complete", json!({
            "toolCallId": "call_A", "success": true, "result": { "content": "a.plist: sandbox" }
        })),
        ev("2026-07-12T07:27:18.000Z", "tool.execution_complete", json!({
            "toolCallId": "call_B", "success": false, "result": { "content": "boom" }
        })),
    ]
}

#[test]
fn normalizes_events() {
    let n = normalize(&recs());
    assert_eq!(n.messages.len(), 4); // user, assistant(+2 tools), 2 results
    assert_eq!(n.messages[0]["content"][0]["text"], "修沙盒问题");
    let a = &n.messages[1];
    assert_eq!(a["content"][0]["text"], "我先搜一下。");
    assert_eq!(a["content"][1]["name"], "Grep");
    assert_eq!(a["content"][1]["input"]["pattern"], "sandbox");
    assert_eq!(a["content"][2]["name"], "Bash");
    assert_eq!(n.messages[2]["content"][0]["tool_use_id"], "call_A");
    assert_eq!(n.messages[3]["content"][0]["is_error"], true);
    assert_eq!(n.model.as_deref(), Some("gpt-5.6"));
    assert_eq!(n.cwd.as_deref(), Some("/tmp/shhh"));
    assert_eq!(n.session_id.as_deref(), Some("d34d-1111"));
    assert_eq!(n.first_ts.as_deref(), Some("2026-07-12T07:27:14.000Z"));
}

#[test]
fn detects_paths_and_uuids() {
    let new = Path::new("/x/.copilot/session-state/abcd-1/events.jsonl");
    let old = Path::new("/x/.copilot/session-state/abcd-2.jsonl");
    assert!(looks_copilot_path(new));
    assert!(looks_copilot_path(old));
    assert!(!looks_copilot_path(Path::new("/x/projects/-tmp/abcd.jsonl")));
    assert_eq!(session_uuid(new), "abcd-1");
    assert_eq!(session_uuid(old), "abcd-2");
}
