use super::*;
use llm_connector::types::Role;
use serde_json::json;

#[test]
fn rejects_call_outputs_without_a_preceding_matching_call() {
    for input in [
        json!([{
            "type":"function_call_output","call_id":"missing_call","output":"done"
        }]),
        json!([
            {"type":"custom_tool_call_output","call_id":"late_call","output":"done"},
            {"type":"custom_tool_call","call_id":"late_call","name":"apply_patch","input":"patch"}
        ]),
        json!([{"type":"tool_search_output","tools":[]}]),
        json!([
            {"type":"function_call","call_id":"duplicate_output","name":"shell","arguments":"{}"},
            {"type":"function_call_output","call_id":"duplicate_output","output":"one"},
            {"type":"function_call_output","call_id":"duplicate_output","output":"two"}
        ]),
        json!([
            {"type":"function_call","call_id":"wrong_kind","name":"shell","arguments":"{}"},
            {"type":"custom_tool_call_output","call_id":"wrong_kind","output":"done"}
        ]),
        json!([
            {"type":"function_call","call_id":"stale_call","name":"shell","arguments":"{}"},
            {"type":"message","role":"user","content":"start another turn"},
            {"type":"function_call_output","call_id":"stale_call","output":"done"}
        ]),
        json!([
            {"type":"function_call","call_id":"stale_bare","name":"shell","arguments":"{}"},
            {"role":"user","content":"start another turn"},
            {"type":"function_call_output","call_id":"stale_bare","output":"done"}
        ]),
    ] {
        let error = decode_request(&json!({ "model":"m", "input":input })).unwrap_err();
        assert!(
            error.contains("no preceding matching call"),
            "unexpected validation error: {error}"
        );
    }
}

#[test]
fn rejects_ambiguous_duplicate_call_ids_and_interleaved_call_groups() {
    for input in [
        json!([
            {"type":"function_call","call_id":"same","name":"first","arguments":"{}"},
            {"type":"custom_tool_call","call_id":"same","name":"second","input":"x"}
        ]),
        json!([
            {"type":"function_call","call_id":"c1","name":"first","arguments":"{}"},
            {"type":"function_call","call_id":"c2","name":"second","arguments":"{}"},
            {"type":"function_call_output","call_id":"c1","output":"one"},
            {"type":"function_call","call_id":"c3","name":"third","arguments":"{}"}
        ]),
        json!([
            {"type":"function_call","call_id":"reused","name":"first","arguments":"{}"},
            {"type":"function_call_output","call_id":"reused","output":"one"},
            {"role":"user","content":"next turn"},
            {"type":"function_call","call_id":"reused","name":"second","arguments":"{}"}
        ]),
    ] {
        let error = decode_request(&json!({"model":"m","input":input})).unwrap_err();
        assert!(
            error.contains("ambiguous"),
            "unexpected validation error: {error}"
        );
    }
}

// Thinking chat upstreams reject tool-call history without reasoning, and MiniMax rejects
// `role:system` anywhere but the head — the decoder must bridge reasoning items onto their
// assistant turn and merge all system/developer text into one leading system message.
#[test]
fn bridges_reasoning_and_collapses_system_into_head() {
    let req = json!({
        "model": "m",
        "instructions": "You are Codex.",
        "input": [
            { "type": "message", "role": "user", "content": [{ "type": "input_text", "text": "run ls" }] },
            { "type": "reasoning", "summary": [{ "type": "summary_text", "text": "need to list" }] },
            { "type": "function_call", "call_id": "c1", "name": "shell", "arguments": "{}" },
            { "type": "function_call_output", "call_id": "c1", "output": "a.txt" },
            { "type": "message", "role": "developer", "content": [{ "type": "input_text", "text": "be careful" }] },
            { "type": "message", "role": "user", "content": [{ "type": "input_text", "text": "again" }] }
        ]
    });
    let ir = decode_request(&req).unwrap();
    let roles: Vec<_> = ir
        .messages
        .iter()
        .map(|m| format!("{:?}", m.role))
        .collect();
    // exactly ONE system message, at the head, carrying instructions + the developer item
    assert_eq!(roles, vec!["System", "User", "Assistant", "Tool", "User"]);
    assert_eq!(
        ir.messages[0].content_as_text(),
        "You are Codex.\n\nbe careful"
    );
    // the reasoning that produced the tool call rides the tool-call assistant turn
    assert_eq!(
        ir.messages[2].reasoning_content.as_deref(),
        Some("need to list")
    );
    assert_eq!(ir.messages[2].tool_calls.as_ref().unwrap()[0].id, "c1");
}

#[test]
fn bridges_call_item_reasoning_without_duplicate_parallel_copies() {
    let req = json!({
        "model":"m",
        "input":[
            {"type":"reasoning","summary":[{"type":"summary_text","text":"inspect both"}]},
            {"type":"function_call","call_id":"c1","name":"first","arguments":"{}",
             "reasoning_content":"inspect both"},
            {"type":"function_call","call_id":"c2","name":"second","arguments":"{}",
             "reasoning_content":"inspect both"},
            {"type":"function_call_output","call_id":"c1","output":"one"},
            {"type":"function_call_output","call_id":"c2","output":"two"}
        ]
    });

    let ir = decode_request(&req).unwrap();
    assert_eq!(ir.messages[0].role, Role::Assistant);
    assert_eq!(
        ir.messages[0].reasoning_content.as_deref(),
        Some("inspect both")
    );
    assert_eq!(ir.messages[0].tool_calls.as_ref().unwrap().len(), 2);

    let item_only = json!({
        "model":"m",
        "input":[
            {"type":"function_call","call_id":"c3","name":"third","arguments":"{}",
             "reasoning_content":"cached reasoning"},
            {"type":"function_call_output","call_id":"c3","output":"three"}
        ]
    });
    let ir = decode_request(&item_only).unwrap();
    assert_eq!(
        ir.messages[0].reasoning_content.as_deref(),
        Some("cached reasoning")
    );
}
