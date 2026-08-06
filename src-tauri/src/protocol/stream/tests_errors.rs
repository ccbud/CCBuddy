use super::*;
use super::super::Wire;

#[test]
fn chat_error_events_are_terminal_for_translated_clients() {
    let mut responses =
        Transcoder::new(Wire::OpenAiChat, Wire::OpenAiResponses, "alias-x").unwrap();
    let mut responses_out =
        responses.push(r#"data: {"choices":[{"index":0,"delta":{"content":"partial"}}]}"#);
    responses_out.push_str(
        &responses
            .push(r#"data: {"error":{"type":"server_error","message":"upstream exploded"}}"#),
    );
    responses_out.push_str(&responses.finish());
    assert!(responses_out.contains(r#""type":"response.failed""#));
    assert!(responses_out.contains("upstream exploded"));
    assert!(!responses_out.contains(r#""type":"response.completed""#));
    assert!(responses.done());
    assert!(!responses.succeeded());

    let mut anthropic = Transcoder::new(Wire::OpenAiChat, Wire::Anthropic, "claude-x").unwrap();
    let mut anthropic_out =
        anthropic.push(r#"data: {"choices":[{"index":0,"delta":{"content":"partial"}}]}"#);
    anthropic_out.push_str(
        &anthropic
            .push(r#"data: {"error":{"type":"server_error","message":"upstream exploded"}}"#),
    );
    anthropic_out.push_str(&anthropic.finish());
    assert!(anthropic_out.contains("event: error"));
    assert!(anthropic_out.contains("upstream exploded"));
    assert!(!anthropic_out.contains("event: message_stop"));
    assert!(anthropic.done());
    assert!(!anthropic.succeeded());
}

#[test]
fn transport_failure_cannot_be_finalized_as_success() {
    for (provider, client) in [
        (Wire::OpenAiChat, Wire::Anthropic),
        (Wire::OpenAiChat, Wire::OpenAiResponses),
        (Wire::Anthropic, Wire::OpenAiResponses),
    ] {
        let mut tc = Transcoder::new(provider, client, "alias-x").unwrap();
        let mut out = tc.fail("upstream stream transport error");
        out.push_str(&tc.finish());
        assert!(tc.done());
        assert!(!tc.succeeded());
        assert!(out.contains("upstream stream transport error"));
        assert!(!out.contains("response.completed"));
        assert!(!out.contains("event: message_stop"));
    }
}

#[test]
fn premature_clean_eof_fails_but_reported_stop_reasons_can_finalize() {
    for (provider, client) in [
        (Wire::OpenAiChat, Wire::Anthropic),
        (Wire::OpenAiChat, Wire::OpenAiResponses),
        (Wire::Anthropic, Wire::OpenAiResponses),
    ] {
        let mut tc = Transcoder::new(provider, client, "alias-x").unwrap();
        tc.push(match provider {
            Wire::Anthropic => {
                r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#
            }
            _ => r#"data: {"choices":[{"index":0,"delta":{"content":"partial"}}]}"#,
        });
        let out = tc.finish();
        assert!(tc.done());
        assert!(!tc.succeeded());
        assert!(out.contains("upstream stream ended before"));
        assert!(!out.contains("response.completed"));
        assert!(!out.contains("event: message_stop"));
    }

    let mut chat_responses =
        Transcoder::new(Wire::OpenAiChat, Wire::OpenAiResponses, "alias-x").unwrap();
    chat_responses.push(
        r#"data: {"choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"#,
    );
    let out = chat_responses.finish();
    assert!(out.contains("response.completed"));
    assert!(chat_responses.succeeded());

    let mut chat_anthropic =
        Transcoder::new(Wire::OpenAiChat, Wire::Anthropic, "claude-x").unwrap();
    chat_anthropic.push(
        r#"data: {"choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"#,
    );
    let out = chat_anthropic.finish();
    assert!(out.contains("event: message_stop"));
    assert!(chat_anthropic.succeeded());

    let mut anthropic =
        Transcoder::new(Wire::Anthropic, Wire::OpenAiResponses, "alias-x").unwrap();
    anthropic.push(
        r#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
    );
    let out = anthropic.finish();
    assert!(out.contains("response.completed"));
    assert!(anthropic.succeeded());
}

#[test]
fn max_token_truncation_emits_incomplete_instead_of_completed() {
    let mut chat = Transcoder::new(Wire::OpenAiChat, Wire::OpenAiResponses, "alias-x").unwrap();
    let mut chat_out = chat.push(
        r#"data: {"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":"length"}]}"#,
    );
    chat_out.push_str(&chat.push("data: [DONE]"));
    assert!(chat_out.contains("response.incomplete"));
    assert!(chat_out.contains(r#""reason":"max_output_tokens""#));
    assert!(!chat_out.contains("response.completed"));
    assert!(chat.done());
    assert!(!chat.succeeded());

    let mut anthropic =
        Transcoder::new(Wire::Anthropic, Wire::OpenAiResponses, "alias-x").unwrap();
    let mut anthropic_out = anthropic.push(
        r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
    );
    anthropic_out.push_str(&anthropic.push(
        r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}"#,
    ));
    anthropic_out.push_str(&anthropic.push(
        r#"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":8}}"#,
    ));
    anthropic_out.push_str(&anthropic.push(r#"data: {"type":"message_stop"}"#));
    assert!(anthropic_out.contains("response.incomplete"));
    assert!(anthropic_out.contains(r#""reason":"max_output_tokens""#));
    assert!(!anthropic_out.contains("response.completed"));
    assert!(anthropic.done());
    assert!(!anthropic.succeeded());
}
