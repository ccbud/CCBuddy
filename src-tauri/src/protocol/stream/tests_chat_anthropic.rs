use super::super::Wire;
use super::*;

#[test]
fn transcodes_text_and_split_tool_call() {
    let mut tc = ChatToAnthropic::new("claude-x");
    let mut out = String::new();
    // role primer, then text, then a tool call split across two chunks, then finish + usage
    out.push_str(
        &tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}"),
    );
    out.push_str(
        &tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Let me \"}}]}"),
    );
    out.push_str(
        &tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"check.\"}}]}"),
    );
    out.push_str(&tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"pa\"},\"extra_content\":{\"google\":{\"thought_signature\":\"sig-stream-abc\"}}}]}}]}"));
    out.push_str(&tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"a.txt\\\"}\"}}]}}]}"));
    out.push_str(&tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":9}}"));
    out.push_str(&tc.push("data: [DONE]"));

    // ordered events present (serde_json sorts object keys, so assert on substrings, not key order)
    assert!(out.contains("event: message_start"));
    assert!(
        out.find("event: message_start").unwrap() < out.find("event: content_block_start").unwrap()
    );
    assert!(
        out.find("event: content_block_start").unwrap() < out.find("event: message_delta").unwrap()
    );
    assert!(out.find("event: message_delta").unwrap() < out.find("event: message_stop").unwrap());
    // text block: a text content_block_start + its two text deltas
    assert!(out.contains(r#""type":"text""#));
    assert!(out.contains("text_delta") && out.contains(r#""text":"Let me ""#));
    assert!(out.contains(r#""text":"check.""#));
    // tool block: tool_use start carries id+name; args reassembled across fragments
    assert!(out.contains(r#""type":"tool_use""#));
    assert!(out.contains(r#""id":"call_1""#) && out.contains(r#""name":"read_file""#));
    assert!(out.contains("input_json_delta") && out.contains(r#""partial_json":"{\"pa""#));
    assert!(out.contains(r#""partial_json":"th\":\"a.txt\"}""#));
    // closes both blocks (index 0 text, index 1 tool), tool_use stop, usage, terminal stop
    assert!(out.contains(r#""index":0,"type":"content_block_stop""#));
    assert!(out.contains(r#""index":1,"type":"content_block_stop""#));
    assert!(out.contains(r#""stop_reason":"tool_use""#));
    assert!(out.contains(r#""output_tokens":9"#));
    assert!(out.contains("event: message_stop"));
    assert_eq!(tc.input_tokens(), 20);
    let captured = tc.captured_tool_calls();
    assert_eq!(captured.len(), 1);
    assert_eq!(captured[0].call_id, "call_1");
    assert_eq!(captured[0].arguments, r#"{"path":"a.txt"}"#);
    assert_eq!(
        captured[0].thought_signature.as_deref(),
        Some("sig-stream-abc")
    );
}

#[test]
fn keeps_no_index_parallel_calls_with_the_same_id_distinct() {
    let mut tc = ChatToAnthropic::new("claude-x");
    let mut out = String::new();
    out.push_str(&tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"id\":\"same-call\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"query\\\":\\\"same\\\"}\"},\"extra_content\":{\"google\":{\"thought_signature\":\"sig-same-id\"}}},{\"id\":\"same-call\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"query\\\":\\\"same\\\"}\"}}]}}]}\n"));
    out.push_str(&tc.push(
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n",
    ));
    out.push_str(&tc.push("data: [DONE]\n"));

    let captured = tc.captured_tool_calls();
    assert_eq!(captured.len(), 2);
    assert_eq!(captured[0].arguments, r#"{"query":"same"}"#);
    assert_eq!(captured[1].arguments, r#"{"query":"same"}"#);
    assert_eq!(
        captured[0].thought_signature.as_deref(),
        Some("sig-same-id")
    );
    assert!(captured[1].thought_signature.is_none());
    assert!(out.contains(r#""index":0,"type":"content_block_start""#));
    assert!(out.contains(r#""index":1,"type":"content_block_start""#));
}

#[test]
fn plain_text_only() {
    let mut tc = ChatToAnthropic::new("claude-x");
    let mut out = String::new();
    out.push_str(&tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"}}]}"));
    out.push_str(
        &tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"),
    );
    out.push_str(&tc.push("data: [DONE]"));
    assert!(out.contains("text_delta") && out.contains(r#""text":"hello""#));
    assert!(out.contains(r#""stop_reason":"end_turn""#));
    assert!(out.contains("event: message_stop"));
}

// The gateway's abort guard relies on done() flipping as soon as push() emits the terminal
// client event — that is the moment Responses clients (Codex) hang up, before upstream EOF.
#[test]
fn done_flips_on_terminal_event_before_eof() {
    let mut tc = Transcoder::new(Wire::Anthropic, Wire::OpenAiResponses, "alias-x").unwrap();
    tc.push("data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":3}}}\n");
    tc.push("data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}\n");
    tc.push("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n");
    assert!(!tc.done());
    let out = tc.push("data: {\"type\":\"message_stop\"}\n");
    assert!(out.contains("response.completed"));
    assert!(tc.done());

    let mut tc = Transcoder::new(Wire::OpenAiChat, Wire::Anthropic, "claude-x").unwrap();
    tc.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"}}]}");
    assert!(!tc.done());
    let out = tc.push("data: [DONE]");
    assert!(out.contains("event: message_stop"));
    assert!(tc.done());
}
