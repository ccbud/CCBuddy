use super::*;
use super::super::openai_responses::response_scoped_call_id;

#[test]
fn chat_to_responses_text_and_split_tool_call() {
    let mut tc = ChatToResponses::new("alias-x");
    let mut out = String::new();
    out.push_str(&tc.push("data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}"));
    out.push_str(
        &tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Let me \"}}]}"),
    );
    out.push_str(
        &tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"check.\"}}]}"),
    );
    out.push_str(&tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"shell\",\"arguments\":\"{\\\"co\"}}]}}]}"));
    out.push_str(&tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"mmand\\\":[\\\"ls\\\"]}\"}}]}}]}"));
    out.push_str(&tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":9,\"prompt_tokens_details\":{\"cached_tokens\":7}}}"));
    out.push_str(&tc.push("data: [DONE]"));

    // ordered: created → text deltas → item done events → completed
    let created = out.find(r#""type":"response.created""#).unwrap();
    let first_delta = out.find(r#""type":"response.output_text.delta""#).unwrap();
    let item_done = out.find(r#""type":"response.output_item.done""#).unwrap();
    let completed = out.find(r#""type":"response.completed""#).unwrap();
    assert!(created < first_delta && first_delta < item_done && item_done < completed);
    // token-by-token text deltas
    assert!(out.contains(r#""delta":"Let me ""#));
    assert!(out.contains(r#""delta":"check.""#));
    // Codex materializes items from output_item.done: full text + reassembled arguments
    assert!(out.contains(r#""text":"Let me check.""#));
    let client_call_id = response_scoped_call_id("resp_chatcmpl-1", 1);
    assert!(
        out.contains(&format!(r#""call_id":"{}""#, client_call_id))
            && out.contains(r#""name":"shell""#)
    );
    assert!(out.contains(r#""arguments":"{\"command\":[\"ls\"]}""#));
    // completed carries id + usage, incl. the prompt cache detail Codex reports
    assert!(out.contains(r#""id":"resp_chatcmpl-1""#));
    assert!(out.contains(r#""input_tokens":20"#) && out.contains(r#""output_tokens":9"#));
    assert!(out.contains(r#""cached_tokens":7"#));
    assert_eq!(tc.input_tokens(), 20);
    assert_eq!(tc.output_tokens(), 9);
    // captured for the gateway's signature cache, keyed by the call_id Codex echoes back
    let captured = tc.captured_tool_calls();
    assert_eq!(captured.len(), 1);
    assert_eq!(captured[0].call_id, client_call_id);
    assert_eq!(captured[0].arguments, r#"{"command":["ls"]}"#);
    // finish is idempotent — [DONE] already closed the stream
    assert_eq!(tc.finish(), "");
}

// Gemini's OpenAI-compatible stream omits `index` and can repeat ids across parallel calls;
// before the fix every no-index fragment collapsed into slot 0 (one garbled call), so Codex
// never received usable tool calls from a Gemini chat upstream.
#[test]
fn chat_to_responses_keeps_no_index_parallel_calls_distinct() {
    let mut tc = ChatToResponses::new("alias-x");
    let mut out = String::new();
    out.push_str(&tc.push("data: {\"id\":\"chatcmpl-2\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"id\":\"same-call\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"query\\\":\\\"a\\\"}\"},\"extra_content\":{\"google\":{\"thought_signature\":\"sig-parallel\"}}},{\"id\":\"same-call\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"query\\\":\\\"b\\\"}\"}}]}}]}\n"));
    out.push_str(&tc.push(
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n",
    ));
    out.push_str(&tc.push("data: [DONE]\n"));

    // two distinct function_call items, each with its own arguments
    assert!(out.contains(r#""output_index":0"#) && out.contains(r#""output_index":1"#));
    assert!(out.contains(r#""arguments":"{\"query\":\"a\"}""#));
    assert!(out.contains(r#""arguments":"{\"query\":\"b\"}""#));
    let captured = tc.captured_tool_calls();
    assert_eq!(captured.len(), 2);
    assert_ne!(captured[0].call_id, captured[1].call_id);
    assert_eq!(
        captured[0].call_id,
        response_scoped_call_id("resp_chatcmpl-2", 0)
    );
    assert_eq!(
        captured[1].call_id,
        response_scoped_call_id("resp_chatcmpl-2", 1)
    );
    assert!(out.contains(&format!(r#""call_id":"{}""#, captured[0].call_id)));
    assert!(out.contains(&format!(r#""call_id":"{}""#, captured[1].call_id)));
    assert_eq!(captured[0].arguments, r#"{"query":"a"}"#);
    assert_eq!(captured[1].arguments, r#"{"query":"b"}"#);
    // the Gemini thought signature is captured for the session cache (restore next turn)
    assert_eq!(
        captured[0].thought_signature.as_deref(),
        Some("sig-parallel")
    );
    assert!(captured[1].thought_signature.is_none());
}

// Some models emit tool-call fragments that never carry a function name; forwarding them
// gives Codex an unexecutable call whose echo the upstream then rejects — drop them instead.
#[test]
fn chat_to_responses_skips_nameless_tool_calls() {
    let mut tc = ChatToResponses::new("alias-x");
    let mut out = String::new();
    out.push_str(&tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{}\"}}]}}]}"));
    out.push_str(&tc.push(
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
    ));
    out.push_str(&tc.push("data: [DONE]"));
    assert!(!out.contains("response.function_call_arguments.done"));
    assert!(
        out.contains(r#""output":[]"#),
        "completed output stays empty: {}",
        out
    );
    assert!(out.contains(r#""type":"response.completed""#));
    assert!(tc.captured_tool_calls().is_empty());
}
