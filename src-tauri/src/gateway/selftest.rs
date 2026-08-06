use serde_json::{json, Value};

use crate::store;

use super::mock::start_mock_upstream;
use super::selftest_xlate::{selftest_reverse_and_codex, selftest_translation};

/// End-to-end gateway test against the mock upstream: routing + response model rewrite for both
/// buffered JSON and streaming SSE. Mutates CCBUD_HOME config (only called in a throwaway run).
pub async fn gateway_selftest(gport: u16) -> Value {
    if gport == 0 {
        return json!({ "err": "gateway not running" });
    }
    let mock = match start_mock_upstream().await {
        Some(p) => p,
        None => return json!({ "err": "mock failed to start" }),
    };
    let cfg = json!({ "port": gport, "activeProviderId":"mock", "providers":[
        { "id":"mock","name":"Mock","baseUrl":format!("http://127.0.0.1:{}", mock),"authToken":"k","defaultModel":"upstream-model","smallFastModel":"upstream-model","mapDefaultModels":true,"models":[{"alias":"test-alias","upstream":"upstream-model"}] }
    ]});
    store::write_config(cfg);
    tokio::time::sleep(std::time::Duration::from_millis(80)).await;

    let client = reqwest::Client::new();
    let base = format!("http://127.0.0.1:{}/v1/messages", gport);

    let ns = client
        .post(&base)
        .json(&json!({ "model":"test-alias","max_tokens":8,"messages":[{"role":"user","content":"hi"}] }))
        .send()
        .await;
    let (ns_status, ns_model) = match ns {
        Ok(r) => {
            let s = r.status().as_u16();
            let j: Value = r.json().await.unwrap_or_else(|_| json!({}));
            (s, j.get("model").and_then(|m| m.as_str()).unwrap_or("").to_string())
        }
        Err(e) => (0, format!("ERR:{}", e)),
    };

    let stm = client
        .post(&base)
        .json(&json!({ "model":"test-alias","stream":true,"max_tokens":8,"messages":[{"role":"user","content":"hi"}] }))
        .send()
        .await;
    let (st_status, st_text) = match stm {
        Ok(r) => (r.status().as_u16(), r.text().await.unwrap_or_default()),
        Err(e) => (0, format!("ERR:{}", e)),
    };

    // count_tokens — mock 404s, so the gateway must estimate locally
    let ct = client
        .post(format!("http://127.0.0.1:{}/v1/messages/count_tokens", gport))
        .json(&json!({ "model":"test-alias","messages":[{"role":"user","content":"hello world this is a token counting test"}] }))
        .send()
        .await;
    let (ct_status, ct_tokens, ct_estimated) = match ct {
        Ok(r) => {
            let s = r.status().as_u16();
            let estimated = r.headers().get("x-ccbud-tokens").and_then(|v| v.to_str().ok()) == Some("estimated");
            let j: Value = r.json().await.unwrap_or_else(|_| json!({}));
            (s, j.get("input_tokens").and_then(|v| v.as_i64()).unwrap_or(-1), estimated)
        }
        Err(_) => (0, -1, false),
    };
    let (cfg2, tx_ns_status, tx_ns_anthropic, tx_ns_text, tx_ns_model, tx_st_status, tx_st_text,
        rx_status, rx_anthropic, rx_text) = selftest_translation(&client, &base, gport, mock).await;

    let (rev_status, rev_is_chat, rev_text, cdx_status, cdx_is_response, cdx_text, cdx_st_status,
        cdx_st_text, cdx_chat_status, cdx_chat_text) =
        selftest_reverse_and_codex(&client, gport, mock, &cfg2).await;

    json!({
        "nonStreamStatus": ns_status,
        "nonStreamModel": ns_model,
        "nonStreamRewritten": ns_model == "test-alias",
        "xlateResponsesStatus": rx_status,
        "xlateResponsesIsAnthropic": rx_anthropic,
        "xlateResponsesText": rx_text,
        "revChatStatus": rev_status,
        "revChatIsChatCompletion": rev_is_chat,
        "revChatText": rev_text,
        "streamStatus": st_status,
        "streamHasStart": st_text.contains("message_start"),
        "streamRewritten": st_text.contains("\"test-alias\"") && !st_text.contains("upstream-model"),
        "countTokensStatus": ct_status,
        "countTokensEstimated": ct_estimated,
        "countTokens": ct_tokens,
        // protocol translation (messages→chat)
        "xlateNonStreamStatus": tx_ns_status,
        "xlateNonStreamIsAnthropic": tx_ns_anthropic,
        "xlateNonStreamText": tx_ns_text,
        "xlateNonStreamModel": tx_ns_model,
        "xlateStreamStatus": tx_st_status,
        "xlateStreamHasStart": tx_st_text.contains("message_start"),
        "xlateStreamHasStop": tx_st_text.contains("message_stop"),
        // incremental transcode: OpenAI chunks → Anthropic text_delta events (text split across
        // chunks), a real content_block_delta, and end_turn stop.
        "xlateStreamIncremental": tx_st_text.contains("content_block_delta") && tx_st_text.contains("text_delta"),
        "xlateStreamText": tx_st_text.contains("from chat"),
        "xlateStreamStop": tx_st_text.contains("\"stop_reason\":\"end_turn\""),
        // Codex (Responses client): buffered translate + incremental stream transcoders. Codex
        // materializes items from response.output_item.done and requires response.completed.
        "codexNonStreamStatus": cdx_status,
        "codexNonStreamIsResponse": cdx_is_response,
        "codexNonStreamText": cdx_text,
        "codexAnthropicStreamStatus": cdx_st_status,
        "codexAnthropicStreamDelta": cdx_st_text.contains("response.output_text.delta"),
        "codexAnthropicStreamItemDone": cdx_st_text.contains("response.output_item.done"),
        "codexAnthropicStreamCompleted": cdx_st_text.contains("response.completed"),
        "codexAnthropicStreamText": cdx_st_text.contains("hi from anthropic"),
        "codexChatStreamStatus": cdx_chat_status,
        "codexChatStreamDelta": cdx_chat_text.contains("response.output_text.delta"),
        "codexChatStreamItemDone": cdx_chat_text.contains("response.output_item.done"),
        "codexChatStreamCompleted": cdx_chat_text.contains("response.completed"),
        "codexChatStreamText": cdx_chat_text.contains("from chat"),
    })
}
