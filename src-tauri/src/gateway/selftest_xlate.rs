use serde_json::{json, Value};

use crate::store;

#[allow(clippy::type_complexity)]
pub(super) async fn selftest_translation(
    client: &reqwest::Client,
    base: &str,
    gport: u16,
    mock: u16,
) -> (Value, u16, bool, String, String, u16, String, u16, bool, String) {
    // ---- protocol translation: Claude Code (Anthropic /v1/messages) → an OpenAI-Chat provider ----
    // Reconfigure the mock provider to speak openai-chat, then hit /v1/messages and prove the
    // response comes back Anthropic-shaped (non-stream) and as a valid Anthropic SSE (stream).
    let cfg2 = json!({ "port": gport, "activeProviderId":"mockoa", "providers":[
        { "id":"mockoa","name":"MockOpenAI","baseUrl":format!("http://127.0.0.1:{}", mock),"authToken":"k","protocol":"openai-chat","defaultModel":"gpt-mock","smallFastModel":"gpt-mock","mapDefaultModels":true,"models":[{"alias":"test-alias","upstream":"gpt-mock"}] }
    ]});
    store::write_config(cfg2.clone());
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let tx_ns = client
        .post(base)
        .json(&json!({ "model":"test-alias","max_tokens":8,"messages":[{"role":"user","content":"hi"}] }))
        .send()
        .await;
    let (tx_ns_status, tx_ns_anthropic, tx_ns_text, tx_ns_model) = match tx_ns {
        Ok(r) => {
            let s = r.status().as_u16();
            let j: Value = r.json().await.unwrap_or_else(|_| json!({}));
            let is_msg = j.get("type").and_then(|v| v.as_str()) == Some("message");
            let text = j.get("content").and_then(|c| c.as_array()).and_then(|a| a.first())
                .and_then(|b| b.get("text")).and_then(|v| v.as_str()).unwrap_or("").to_string();
            let model = j.get("model").and_then(|v| v.as_str()).unwrap_or("").to_string();
            (s, is_msg, text, model)
        }
        Err(e) => (0, false, format!("ERR:{}", e), String::new()),
    };

    let tx_st = client
        .post(base)
        .json(&json!({ "model":"test-alias","stream":true,"max_tokens":8,"messages":[{"role":"user","content":"hi"}] }))
        .send()
        .await;
    let (tx_st_status, tx_st_text) = match tx_st {
        Ok(r) => (r.status().as_u16(), r.text().await.unwrap_or_default()),
        Err(e) => (0, format!("ERR:{}", e)),
    };

    // ---- protocol translation: Claude Code (Anthropic /v1/messages) → an OpenAI-Responses provider ----
    let cfg3 = json!({ "port": gport, "activeProviderId":"mockre", "providers":[
        { "id":"mockre","name":"MockResponses","baseUrl":format!("http://127.0.0.1:{}", mock),"authToken":"k","protocol":"openai-responses","defaultModel":"gpt-mock","smallFastModel":"gpt-mock","mapDefaultModels":true,"models":[{"alias":"test-alias","upstream":"gpt-mock"}] }
    ]});
    store::write_config(cfg3);
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let rx = client
        .post(base)
        .json(&json!({ "model":"test-alias","max_tokens":8,"messages":[{"role":"user","content":"hi"}] }))
        .send()
        .await;
    let (rx_status, rx_anthropic, rx_text) = match rx {
        Ok(r) => {
            let s = r.status().as_u16();
            let j: Value = r.json().await.unwrap_or_else(|_| json!({}));
            let is_msg = j.get("type").and_then(|v| v.as_str()) == Some("message");
            let text = j.get("content").and_then(|c| c.as_array()).and_then(|a| a.first())
                .and_then(|b| b.get("text")).and_then(|v| v.as_str()).unwrap_or("").to_string();
            (s, is_msg, text)
        }
        Err(e) => (0, false, format!("ERR:{}", e)),
    };
    (cfg2, tx_ns_status, tx_ns_anthropic, tx_ns_text, tx_ns_model, tx_st_status, tx_st_text,
        rx_status, rx_anthropic, rx_text)
}

#[allow(clippy::type_complexity)]
pub(super) async fn selftest_reverse_and_codex(
    client: &reqwest::Client,
    gport: u16,
    mock: u16,
    cfg2: &Value,
) -> (u16, bool, String, u16, bool, String, u16, String, u16, String) {
    // ---- reverse: an OpenAI-Chat client (/v1/chat/completions) → an Anthropic provider ----
    let cfg4 = json!({ "port": gport, "activeProviderId":"mockan", "providers":[
        { "id":"mockan","name":"MockAnthropic","baseUrl":format!("http://127.0.0.1:{}", mock),"authToken":"k","protocol":"anthropic","defaultModel":"claude-mock","smallFastModel":"claude-mock","mapDefaultModels":true,"models":[{"alias":"test-alias","upstream":"claude-mock"}] }
    ]});
    store::write_config(cfg4);
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let rev = client
        .post(format!("http://127.0.0.1:{}/v1/chat/completions", gport))
        .json(&json!({ "model":"test-alias","messages":[{"role":"user","content":"hi"}] }))
        .send()
        .await;
    let (rev_status, rev_is_chat, rev_text) = match rev {
        Ok(r) => {
            let s = r.status().as_u16();
            let j: Value = r.json().await.unwrap_or_else(|_| json!({}));
            let is_chat = j.get("object").and_then(|v| v.as_str()) == Some("chat.completion");
            let text = j.get("choices").and_then(|c| c.as_array()).and_then(|a| a.first())
                .and_then(|c| c.get("message")).and_then(|m| m.get("content")).and_then(|v| v.as_str()).unwrap_or("").to_string();
            (s, is_chat, text)
        }
        Err(e) => (0, false, format!("ERR:{}", e)),
    };

    // ---- Codex (OpenAI-Responses client, /v1/responses) → an Anthropic provider ----
    // The shape Codex sends with wire_api="responses": instructions + item-based input + flattened
    // function tools. Non-stream proves the buffered translate; stream proves the incremental
    // Anthropic→Responses transcoder (item done events + terminal response.completed).
    let codex_body = json!({ "model":"test-alias", "instructions":"be nice",
        "input":[{ "type":"message","role":"user","content":[{ "type":"input_text","text":"hi" }] }],
        "tools":[{ "type":"function","name":"shell","description":"run","parameters":{ "type":"object" } }],
        "tool_choice":"auto", "store": false });
    let cdx = client
        .post(format!("http://127.0.0.1:{}/v1/responses", gport))
        .json(&codex_body)
        .send()
        .await;
    let (cdx_status, cdx_is_response, cdx_text) = match cdx {
        Ok(r) => {
            let s = r.status().as_u16();
            let j: Value = r.json().await.unwrap_or_else(|_| json!({}));
            let is_resp = j.get("object").and_then(|v| v.as_str()) == Some("response");
            let text = j.get("output_text").and_then(|v| v.as_str()).unwrap_or("").to_string();
            (s, is_resp, text)
        }
        Err(e) => (0, false, format!("ERR:{}", e)),
    };
    let mut codex_stream_body = codex_body.clone();
    codex_stream_body["stream"] = json!(true);
    let cdx_st = client
        .post(format!("http://127.0.0.1:{}/v1/responses", gport))
        .json(&codex_stream_body)
        .send()
        .await;
    let (cdx_st_status, cdx_st_text) = match cdx_st {
        Ok(r) => (r.status().as_u16(), r.text().await.unwrap_or_default()),
        Err(e) => (0, format!("ERR:{}", e)),
    };

    // ---- Codex → an OpenAI-Chat provider (incremental chat→Responses transcoding) ----
    store::write_config(cfg2.clone());
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let cdx_chat = client
        .post(format!("http://127.0.0.1:{}/v1/responses", gport))
        .json(&codex_stream_body)
        .send()
        .await;
    let (cdx_chat_status, cdx_chat_text) = match cdx_chat {
        Ok(r) => (r.status().as_u16(), r.text().await.unwrap_or_default()),
        Err(e) => (0, format!("ERR:{}", e)),
    };
    (rev_status, rev_is_chat, rev_text, cdx_status, cdx_is_response, cdx_text, cdx_st_status,
        cdx_st_text, cdx_chat_status, cdx_chat_text)
}
