use super::*;
use serde_json::json;
use std::path::Path;

#[test]
fn detects_qoder_paths() {
    assert!(looks_qoder_path(Path::new(
        "/h/.qoder/projects/-Users-a-p/1111-uuid.jsonl"
    )));
    assert!(looks_qoder_path(Path::new(
        "/h/.qoderwork/projects/-Users-a-p/1111-uuid.jsonl"
    )));
    // subagent transcripts under the session's own dir route too (search scans them)
    assert!(looks_qoder_path(Path::new(
        "/h/.qoder/projects/-enc/1111-uuid/subagents/agent-x.jsonl"
    )));
    assert!(!looks_qoder_path(Path::new(
        "/h/.claude/projects/-enc/1111-uuid.jsonl"
    )));
    assert!(!looks_qoder_path(Path::new(
        "/h/.qoder/projects/-enc/session-state.json"
    )));
    // projects/ must be DIRECTLY under the qoder root
    assert!(!looks_qoder_path(Path::new(
        "/h/.qoder/sessions/-enc/1111-uuid.jsonl"
    )));
    assert!(!looks_qoder_path(Path::new(
        "/h/qoder/projects/-enc/1111-uuid.jsonl"
    )));
}

#[test]
fn extracts_inline_title_workspace_and_runtime_metadata() {
    let records = vec![
        json!({ "type": "user", "isMeta": true, "message": { "content": "hidden setup" } }),
        json!({ "type": "user", "message": { "content": [{ "type": "tool_result", "content": "not a title" }] } }),
        json!({ "type": "user", "message": { "content": " First real prompt " } }),
        json!({ "type": "summary", "summary": " Summary fallback " }),
        json!({ "type": "last-prompt", "lastPrompt": " Older prompt " }),
        json!({ "type": "last-prompt", "lastPrompt": " Latest prompt " }),
        json!({ "type": "ai-title", "aiTitle": " Generated title " }),
        json!({ "type": "custom-title", "customTitle": " " }),
        json!({ "type": "custom-title", "customTitle": " Chosen title " }),
        json!({ "type": "workspace-directories", "directories": ["/old/workspace"] }),
        json!({ "type": "workspace-directories", "directories": [" ", "/work/project", "/work/secondary"] }),
        json!({ "type": "runtime-config", "model": "basic" }),
        json!({ "type": "runtime-config", "model": " " }),
        json!({ "type": "runtime-config", "model": "ultimate" }),
    ];

    assert_eq!(
        session_title_from(&records).as_deref(),
        Some("Chosen title")
    );
    assert_eq!(working_dir_from(&records).as_deref(), Some("/work/project"));
    assert_eq!(model_from(&records).as_deref(), Some("ultimate"));

    assert_eq!(
        session_title_from(&records[..8]).as_deref(),
        Some("Generated title")
    );
    assert_eq!(
        session_title_from(&records[..6]).as_deref(),
        Some("Latest prompt")
    );
    assert_eq!(
        session_title_from(&records[..4]).as_deref(),
        Some("Summary fallback")
    );
    assert_eq!(
        session_title_from(&records[..3]).as_deref(),
        Some("First real prompt")
    );
}

#[test]
fn normalizes_atomic_assistant_wrappers_and_queued_commands() {
    let records = vec![
        json!({ "type": "runtime-config", "model": "ultimate" }),
        json!({
            "type": "assistant", "uuid": "wrapper-1", "timestamp": "2026-01-01T00:00:00Z",
            "message": {
                "id": "message-1", "role": "assistant", "model": "draft",
                "content": [
                    { "type": "thinking", "thinking": "plan" },
                    { "type": "redacted_thinking", "data": "opaque duplicate" }
                ],
                "usage": { "input_tokens": 1 }, "stop_reason": null
            }
        }),
        json!({
            "type": "assistant", "uuid": "wrapper-2", "timestamp": "2026-01-01T00:00:01Z",
            "message": {
                "id": "message-1", "role": "assistant", "model": "ultimate",
                "content": [{ "type": "text", "text": "checking" }],
                "usage": null, "stop_reason": "tool_use"
            }
        }),
        json!({
            "type": "assistant", "uuid": "wrapper-3", "timestamp": "2026-01-01T00:00:02Z",
            "message": {
                "id": "message-1", "role": "assistant", "model": " ",
                "content": [{ "type": "tool_use", "id": "tool-1", "name": "Read", "input": { "file_path": "/work/file" } }],
                "usage": { "input_tokens": 7, "output_tokens": 3 }, "stop_reason": null
            }
        }),
        json!({
            "type": "attachment", "uuid": "queued-1", "cwd": "/work/project",
            "attachment": { "type": "queued_command", "prompt": "follow up", "commandMode": "agent" }
        }),
        json!({
            "type": "assistant", "uuid": "wrapper-without-id",
            "message": { "role": "assistant", "content": [
                { "type": "redacted_thinking", "data": "drop me" },
                { "type": "text", "text": "kept" }
            ] }
        }),
    ];

    let normalized = normalize_records(&records);
    assert_eq!(normalized.len(), 4);
    assert_eq!(normalized[0]["type"], "runtime-config");

    let assistant = &normalized[1];
    assert_eq!(assistant["uuid"], "wrapper-1");
    assert_eq!(assistant["timestamp"], "2026-01-01T00:00:00Z");
    assert_eq!(assistant["message"]["model"], "ultimate");
    assert_eq!(
        assistant["message"]["usage"],
        json!({ "input_tokens": 7, "output_tokens": 3 })
    );
    assert_eq!(assistant["message"]["stop_reason"], "tool_use");
    assert_eq!(
        assistant["message"]["content"]
            .as_array()
            .unwrap()
            .iter()
            .map(|block| block["type"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec!["thinking", "text", "tool_use"]
    );

    let queued = &normalized[2];
    assert_eq!(queued["type"], "user");
    assert_eq!(queued["uuid"], "queued-1");
    assert_eq!(queued["cwd"], "/work/project");
    assert_eq!(
        queued["message"],
        json!({ "role": "user", "content": "follow up" })
    );
    assert!(queued.get("attachment").is_none());

    assert_eq!(
        normalized[3]["message"]["content"],
        json!([{ "type": "text", "text": "kept" }])
    );
    // The caller's parsed records remain untouched.
    assert_eq!(
        records[1]["message"]["content"].as_array().unwrap().len(),
        2
    );
}
