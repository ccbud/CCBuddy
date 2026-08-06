use super::*;
use serde_json::Value;

fn response_for_event(output: &str, event: &str) -> Value {
    let event_line = format!("event: {}", event);
    let frame = output
        .split("\n\n")
        .find(|frame| frame.lines().next() == Some(event_line.as_str()))
        .unwrap_or_else(|| panic!("missing {event} event in {output}"));
    let data = frame
        .lines()
        .find_map(|line| line.strip_prefix("data: "))
        .unwrap();
    serde_json::from_str::<Value>(data).unwrap()["response"].clone()
}

fn response_id_for_event(output: &str, event: &str) -> String {
    response_for_event(output, event)["id"]
        .as_str()
        .unwrap()
        .to_string()
}

#[test]
fn chat_to_responses_response_ids_are_unique_and_stable() {
    let mut first = ChatToResponses::new("alias-x");
    let mut second = ChatToResponses::new("alias-x");
    let first_fallback = first.resp_id.clone();
    let second_fallback = second.resp_id.clone();
    assert!(first_fallback.starts_with("resp_ccbud_"));
    assert!(second_fallback.starts_with("resp_ccbud_"));
    assert_ne!(first_fallback, second_fallback);

    let mut first_out =
        first.push(r#"data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}"#);
    first_out.push_str(&first.push(
        r#"data: {"id":"chatcmpl-too-late","choices":[{"index":0,"delta":{"content":"hi"}}]}"#,
    ));
    first_out.push_str(&first.push("data: [DONE]"));
    assert_eq!(first.resp_id, first_fallback);
    assert_eq!(
        response_id_for_event(&first_out, "response.created"),
        first_fallback
    );
    assert_eq!(
        response_id_for_event(&first_out, "response.completed"),
        first_fallback
    );

    let second_out = second.push("data: [DONE]");
    assert_eq!(
        response_id_for_event(&second_out, "response.created"),
        second_fallback
    );
    assert_eq!(
        response_id_for_event(&second_out, "response.completed"),
        second_fallback
    );

    let mut upstream = ChatToResponses::new("alias-x");
    let upstream_fallback = upstream.resp_id.clone();
    let mut upstream_out = upstream.push(
        r#"data: {"id":"chatcmpl-early","choices":[{"index":0,"delta":{"role":"assistant"}}]}"#,
    );
    upstream_out.push_str(&upstream.push("data: [DONE]"));
    assert_ne!(upstream.resp_id, upstream_fallback);
    assert_eq!(upstream.resp_id, "resp_chatcmpl-early");
    assert_eq!(
        response_id_for_event(&upstream_out, "response.created"),
        "resp_chatcmpl-early"
    );
    assert_eq!(
        response_id_for_event(&upstream_out, "response.completed"),
        "resp_chatcmpl-early"
    );
}

#[test]
fn anthropic_to_responses_response_ids_are_unique_and_stable() {
    let mut first = AnthropicToResponses::new("alias-x");
    let mut second = AnthropicToResponses::new("alias-x");
    let first_fallback = first.resp_id.clone();
    let second_fallback = second.resp_id.clone();
    assert!(first_fallback.starts_with("resp_ccbud_"));
    assert!(second_fallback.starts_with("resp_ccbud_"));
    assert_ne!(first_fallback, second_fallback);

    let mut first_out = first.push(
        r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
    );
    first_out.push_str(&first.push(
        r#"data: {"type":"message_start","message":{"id":"msg_too_late","usage":{"input_tokens":1}}}"#,
    ));
    first_out.push_str(&first.push(r#"data: {"type":"message_stop"}"#));
    assert_eq!(first.resp_id, first_fallback);
    assert_eq!(
        response_id_for_event(&first_out, "response.created"),
        first_fallback
    );
    assert_eq!(
        response_id_for_event(&first_out, "response.completed"),
        first_fallback
    );

    let second_out = second.push(r#"data: {"type":"message_stop"}"#);
    assert_eq!(
        response_id_for_event(&second_out, "response.created"),
        second_fallback
    );
    assert_eq!(
        response_id_for_event(&second_out, "response.completed"),
        second_fallback
    );

    let mut upstream = AnthropicToResponses::new("alias-x");
    let upstream_fallback = upstream.resp_id.clone();
    let mut upstream_out = upstream.push(
        r#"data: {"type":"message_start","message":{"id":"msg_early","usage":{"input_tokens":1}}}"#,
    );
    upstream_out.push_str(&upstream.push(r#"data: {"type":"message_stop"}"#));
    assert_ne!(upstream.resp_id, upstream_fallback);
    assert_eq!(upstream.resp_id, "resp_msg_early");
    assert_eq!(
        response_id_for_event(&upstream_out, "response.created"),
        "resp_msg_early"
    );
    assert_eq!(
        response_id_for_event(&upstream_out, "response.completed"),
        "resp_msg_early"
    );
}

#[test]
fn streaming_response_item_ids_are_scoped_to_the_response() {
    let chat = |upstream_id: &str| {
        let mut tc = ChatToResponses::new("alias-x");
        let mut out = tc.push(&format!(
            r#"data: {{"id":"{upstream_id}","choices":[{{"index":0,"delta":{{"reasoning_content":"think","content":"answer"}}}}]}}"#
        ));
        out.push_str(&tc.push("data: [DONE]"));
        response_for_event(&out, "response.completed")["output"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|item| item.get("id").and_then(Value::as_str))
            .map(ToString::to_string)
            .collect::<Vec<_>>()
    };
    let first_chat = chat("chatcmpl-first");
    let second_chat = chat("chatcmpl-second");
    assert_eq!(first_chat.len(), 2);
    assert!(first_chat.iter().all(|id| id.contains("chatcmpl-first")));
    assert!(second_chat.iter().all(|id| id.contains("chatcmpl-second")));
    assert!(first_chat.iter().all(|id| !second_chat.contains(id)));

    let anthropic = |message_id: &str| {
        let mut tc = AnthropicToResponses::new("alias-x");
        let mut out = tc.push(&format!(
            r#"data: {{"type":"message_start","message":{{"id":"{message_id}","usage":{{"input_tokens":1}}}}}}"#
        ));
        out.push_str(&tc.push(
            r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
        ));
        out.push_str(&tc.push(
            r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"think"}}"#,
        ));
        out.push_str(&tc.push(
            r#"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        ));
        out.push_str(&tc.push(
            r#"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"answer"}}"#,
        ));
        out.push_str(&tc.push(r#"data: {"type":"message_stop"}"#));
        response_for_event(&out, "response.completed")["output"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|item| item.get("id").and_then(Value::as_str))
            .map(ToString::to_string)
            .collect::<Vec<_>>()
    };
    let first_anthropic = anthropic("msg-first");
    let second_anthropic = anthropic("msg-second");
    assert_eq!(first_anthropic.len(), 2);
    assert!(first_anthropic.iter().all(|id| id.contains("msg-first")));
    assert!(second_anthropic.iter().all(|id| id.contains("msg-second")));
    assert!(first_anthropic
        .iter()
        .all(|id| !second_anthropic.contains(id)));
}
