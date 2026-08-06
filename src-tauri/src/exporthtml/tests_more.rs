use super::build::build_data;
use super::tests::{qoder_fixture, write_jsonl};
use serde_json::{json, Value};
use std::fs;

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
