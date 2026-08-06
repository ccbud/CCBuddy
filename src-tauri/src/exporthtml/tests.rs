use super::parse::parse_jsonl;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub(super) fn qoder_fixture(name: &str) -> (PathBuf, PathBuf) {
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

pub(super) fn write_jsonl(path: &Path, records: &[Value]) {
    let raw = records
        .iter()
        .map(|record| serde_json::to_string(record).unwrap())
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(path, format!("{raw}\n")).unwrap();
}

pub(super) fn streamed_assistant_records() -> Vec<Value> {
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
