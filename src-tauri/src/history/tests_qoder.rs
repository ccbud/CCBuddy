use serde_json::{json, Value};
use std::fs;
use std::path::Path;

use super::edit::delete_session_file;
use super::import::qoder_import_raw;
use super::list::list_sessions;
use super::search::search_sessions;
use super::session::get_session;

// Qoder writes Claude-like atomic event wrappers plus inline metadata into its own tree.
// Rows and detail must use that metadata, merge one assistant response's content blocks,
// retain queued commands as user turns, nest subagents, and remain searchable/exportable.
#[test]
fn qoder_sessions_route_end_to_end() {
    let base = std::env::temp_dir().join("ccbud-qoder-route-test");
    let _ = fs::remove_dir_all(&base);
    let root = base.join(".qoder");
    let proj = root.join("projects").join("-tmp-qproj");
    fs::create_dir_all(&proj).unwrap();
    let uuid = "11111111-1111-4111-8111-111111111111";
    let sess = proj.join(format!("{}.jsonl", uuid));
    let records = vec![
        json!({ "type": "agent-setting", "agentSetting": "triage", "entrypoint": "sdk-cli", "sessionId": uuid }),
        json!({ "type": "last-prompt", "sessionId": uuid, "lastPrompt": "last prompt fallback" }),
        json!({ "type": "ai-title", "sessionId": uuid, "aiTitle": "Qoder 会话" }),
        json!({ "type": "workspace-directories", "sessionId": uuid, "directories": ["/tmp/qproj"] }),
        json!({ "type": "runtime-config", "sessionId": uuid, "model": "ultimate", "reasoningEffort": "high" }),
        json!({
            "type": "user", "uuid": "u1", "timestamp": "2026-06-04T09:47:27.966Z",
            "message": { "role": "user", "content": "qoder needle axolotl" },
            "sessionId": uuid, "version": "1.1.13"
        }),
        json!({
            "type": "assistant", "uuid": "a1", "parentUuid": "u1", "timestamp": "2026-06-04T09:47:32.116Z",
            "message": { "id": "msg_1", "type": "message", "role": "assistant", "model": "wire-model", "content": [
                { "type": "redacted_thinking", "data": "must not render" }
            ]}, "sessionId": uuid
        }),
        json!({
            "type": "assistant", "uuid": "a2", "parentUuid": "a1", "timestamp": "2026-06-04T09:47:32.216Z",
            "message": { "id": "msg_1", "type": "message", "role": "assistant", "content": [
                { "type": "thinking", "thinking": "considering" }
            ]}, "sessionId": uuid
        }),
        json!({
            "type": "assistant", "uuid": "a3", "parentUuid": "a2", "timestamp": "2026-06-04T09:47:32.316Z",
            "message": { "id": "msg_1", "type": "message", "role": "assistant", "content": [
                { "type": "text", "text": "done" }
            ]}, "sessionId": uuid
        }),
        json!({
            "type": "assistant", "uuid": "a4", "parentUuid": "a3", "timestamp": "2026-06-04T09:47:32.416Z",
            "message": {
                "id": "msg_1", "type": "message", "role": "assistant", "stop_reason": "end_turn",
                "usage": { "input_tokens": 100, "cache_creation_input_tokens": 7, "cache_read_input_tokens": 50, "output_tokens": 30 },
                "content": [{ "type": "tool_use", "id": "tu1", "name": "Task", "input": {} }]
            }, "sessionId": uuid
        }),
        json!({
            "type": "attachment", "attachment": { "type": "queued_command", "prompt": "queued narwhal follow-up", "commandMode": false },
            "uuid": "u2", "parentUuid": "a4", "timestamp": "2026-06-04T09:47:35.000Z", "sessionId": uuid
        }),
    ];
    let raw = records
        .iter()
        .map(|record| serde_json::to_string(record).unwrap())
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    fs::write(&sess, raw).unwrap();
    let sub = proj.join(uuid).join("subagents");
    fs::create_dir_all(&sub).unwrap();
    fs::write(
        sub.join("agent-q1.jsonl"),
        format!("{{\"type\":\"assistant\",\"isSidechain\":true,\"agentId\":\"q1\",\"message\":{{\"role\":\"assistant\",\"content\":[{{\"type\":\"text\",\"text\":\"sub quetzal done\"}}]}},\"sessionId\":\"{}\",\"timestamp\":\"2026-06-04T09:47:40.000Z\"}}\n", uuid),
    )
    .unwrap();
    fs::write(
        sub.join("agent-q1.meta.json"),
        "{\"agentType\":\"general-purpose\",\"description\":\"d\",\"toolUseId\":\"tu1\"}",
    )
    .unwrap();

    let config = json!({ "historyDirs": [ root.to_string_lossy() ] });
    let rows = list_sessions(&config, "all", 50);
    assert_eq!(rows.len(), 1, "rows: {:?}", rows);
    let r = &rows[0];
    assert_eq!(r["source"], "qoder");
    assert_eq!(r["id"], format!("qoder:{}", uuid));
    assert_eq!(r["title"], "Qoder 会话");
    assert_eq!(r["autoTitle"], "Qoder 会话");
    assert_eq!(r["cwd"], "/tmp/qproj");
    assert_eq!(r["model"], "ultimate");
    assert_eq!(r["deleted"], false);

    let file = r["file"].as_str().unwrap();
    let d = get_session(file);
    assert_eq!(d["meta"]["assistant"], "Qoder");
    assert_eq!(d["meta"]["source"], "qoder");
    assert_eq!(d["meta"]["id"], format!("qoder:{}", uuid));
    assert_eq!(d["meta"]["title"], "Qoder 会话");
    assert_eq!(d["meta"]["model"], "ultimate");
    assert_eq!(d["meta"]["subagentCount"], 1);
    assert_eq!(d["messages"].as_array().unwrap().len(), 3);
    assert_eq!(d["messages"][0]["content"], "qoder needle axolotl"); // string-content user turn
    let assistant_blocks = d["messages"][1]["content"].as_array().unwrap();
    assert_eq!(
        assistant_blocks
            .iter()
            .filter_map(|block| block.get("type").and_then(Value::as_str))
            .collect::<Vec<_>>(),
        vec!["thinking", "text", "tool_use"]
    );
    assert_eq!(d["messages"][1]["usage"]["inputTokens"], 100);
    assert_eq!(d["messages"][1]["stopReason"], "end_turn");
    assert_eq!(d["messages"][2]["role"], "user");
    assert_eq!(d["messages"][2]["content"], "queued narwhal follow-up");
    assert_eq!(d["subagents"]["tu1"]["messages"][0]["content"][0]["text"], "sub quetzal done");

    // another tool's live file: delete-forever must refuse and leave it on disk
    let del = delete_session_file(file, &config);
    assert_eq!(del["reason"], "foreign");
    assert!(Path::new(file).is_file());

    // content search reaches the main thread and the subagent transcript
    let hits = search_sessions(&config, "all", "axolotl", 10);
    assert_eq!(hits.len(), 1, "{:?}", hits);
    assert_eq!(hits[0]["agent"], "main");
    let hits = search_sessions(&config, "all", "narwhal", 10);
    assert_eq!(hits.len(), 1, "{:?}", hits);
    assert_eq!(hits[0]["agent"], "main");
    let hits = search_sessions(&config, "all", "quetzal", 10);
    assert_eq!(hits.len(), 1, "{:?}", hits);
    assert_eq!(hits[0]["agent"], "tu1");

    let _ = fs::remove_dir_all(&base);
}

// Imported qoder content is rewritten to Claude shape (wrappers merged, queued commands
// materialized) with qoder's own title carried onto __ccbud__; Claude content passes through.
#[test]
fn qoder_imports_are_normalized_with_title() {
    let recs = vec![
        json!({ "type": "ai-title", "aiTitle": "Qoder 导入标题" }),
        json!({ "type": "assistant", "uuid": "w1", "message": { "id": "m1", "role": "assistant", "content": [{ "type": "thinking", "thinking": "t" }] } }),
        json!({ "type": "assistant", "uuid": "w2", "message": { "id": "m1", "role": "assistant", "content": [{ "type": "text", "text": "done" }] } }),
        json!({ "type": "attachment", "attachment": { "type": "queued_command", "prompt": "queued prompt" } }),
    ];
    let (text, normalized) = qoder_import_raw(&recs).expect("sniffs as qoder");
    let assistants: Vec<&Value> = normalized.iter().filter(|r| r["type"] == "assistant").collect();
    assert_eq!(assistants.len(), 1, "wrappers merged: {:?}", normalized);
    assert_eq!(assistants[0]["message"]["content"].as_array().unwrap().len(), 2);
    assert!(normalized
        .iter()
        .any(|r| r["type"] == "user" && r["message"]["content"] == "queued prompt"));
    let first: Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
    assert_eq!(first["__ccbud__"]["title"], "Qoder 导入标题");
    assert!(qoder_import_raw(&[json!({ "type": "user", "message": { "content": "hi" } })]).is_none());
}
