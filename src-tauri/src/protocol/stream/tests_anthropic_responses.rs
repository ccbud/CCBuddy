use super::super::openai_responses::response_scoped_call_id;
use super::*;

#[test]
fn anthropic_to_responses_text_tool_and_thinking() {
    let mut tc = AnthropicToResponses::new("alias-x");
    let mut out = String::new();
    out.push_str(&tc.push(r#"data: {"type":"message_start","message":{"id":"msg_9","usage":{"input_tokens":30,"cache_read_input_tokens":12,"cache_creation_input_tokens":0}}}"#));
    out.push_str(&tc.push(r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#));
    out.push_str(&tc.push(r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#));
    out.push_str(&tc.push(r#"data: {"type":"content_block_stop","index":0}"#));
    out.push_str(&tc.push(r#"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#));
    out.push_str(&tc.push(r#"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Run"}}"#));
    out.push_str(&tc.push(r#"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ning."}}"#));
    out.push_str(&tc.push(r#"data: {"type":"content_block_stop","index":1}"#));
    out.push_str(&tc.push(r#"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"shell","input":{}}}"#));
    out.push_str(&tc.push(r#"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"q\":"}}"#));
    out.push_str(&tc.push(r#"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"x\"}"}}"#));
    out.push_str(&tc.push(r#"data: {"type":"content_block_stop","index":2}"#));
    out.push_str(&tc.push(r#"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":11}}"#));
    out.push_str(&tc.push(r#"data: {"type":"message_stop"}"#));

    let created = out.find(r#""type":"response.created""#).unwrap();
    let completed = out.find(r#""type":"response.completed""#).unwrap();
    assert!(created < completed);
    // thinking → reasoning summary deltas + item
    assert!(
        out.contains(r#""type":"response.reasoning_summary_text.delta""#)
            && out.contains(r#""delta":"hmm""#)
    );
    assert!(out.contains(r#""type":"summary_text""#));
    // text streams as deltas and closes with the full text
    assert!(out.contains(r#""delta":"Run""#) && out.contains(r#""delta":"ning.""#));
    assert!(out.contains(r#""text":"Running.""#));
    // tool_use → function_call item with the reassembled arguments string
    assert!(
        out.contains(&format!(
            r#""call_id":"{}""#,
            response_scoped_call_id("resp_msg_9", 2)
        )) && out.contains(r#""name":"shell""#)
    );
    assert!(out.contains(r#""arguments":"{\"q\":\"x\"}""#));
    // usage: cached reads fold into input_tokens, detail carries them
    assert!(out.contains(r#""input_tokens":42"#));
    assert!(out.contains(r#""cached_tokens":12"#));
    assert!(out.contains(r#""output_tokens":11"#));
    assert!(out.contains(r#""id":"resp_msg_9""#));
    assert_eq!(tc.input_tokens(), 42);
    assert_eq!(tc.output_tokens(), 11);
    // message_stop already completed the stream
    assert_eq!(tc.finish(), "");
}

#[test]
fn anthropic_to_responses_error_is_terminal() {
    let mut tc = AnthropicToResponses::new("alias-x");
    let mut out = String::new();
    out.push_str(&tc.push(
        r#"data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":5}}}"#,
    ));
    out.push_str(&tc.push(
        r#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
    ));
    out.push_str(&tc.finish());
    assert!(out.contains(r#""type":"response.failed""#) && out.contains("Overloaded"));
    // failed is terminal: no completed after it
    assert!(!out.contains(r#""type":"response.completed""#));
}
