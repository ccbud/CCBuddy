use axum::{
    body::{to_bytes, Body},
    http::StatusCode,
    response::Response,
    Router,
};
use serde_json::{json, Value};

use super::targets::json_response;

// ---- mock upstream + end-to-end gateway selftest (debug only) ----

/// Spawn an in-process mock Anthropic-style upstream on a random port. Echoes back the model
/// the gateway forwarded (proving the outgoing rewrite), with usage, as JSON or SSE.
pub async fn start_mock_upstream() -> Option<u16> {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.ok()?;
    let port = listener.local_addr().ok()?.port();
    let app: Router = Router::new().fallback(mock_handler);
    tauri::async_runtime::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    Some(port)
}

async fn mock_handler(req: axum::extract::Request) -> Response {
    let (parts, body) = req.into_parts();
    let path = parts.uri.path().to_string();
    let bytes = to_bytes(body, 1024 * 1024).await.unwrap_or_default();
    if path.ends_with("/count_tokens") || path == "/" {
        // Simulate a provider that implements neither count_tokens nor `HEAD /` → the gateway
        // estimates locally / serves the health-probe fallback.
        return Response::builder()
            .status(404)
            .header("content-type", "application/json")
            .body(Body::from("{\"error\":\"not found\"}"))
            .unwrap();
    }
    let v: Value = serde_json::from_slice(&bytes).unwrap_or_else(|_| json!({}));
    let stream = v.get("stream").and_then(|s| s.as_bool()).unwrap_or(false);
    let model = v.get("model").and_then(|m| m.as_str()).unwrap_or("upstream-model").to_string();
    // OpenAI Chat endpoint: answer in Chat Completions shape so the gateway's protocol translation
    // (Anthropic→chat request, chat→Anthropic response) can be exercised end-to-end. The gateway
    // forces stream=false upstream when translating, so we only need the buffered form here.
    if path.contains("/chat/completions") {
        if stream {
            // OpenAI Chat streaming chunks (text split across two chunks + a usage-bearing final
            // chunk), so the incremental transcoder is exercised end-to-end.
            let sse = format!(
                "data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\"}}}}]}}\n\n\
                 data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"hi \"}}}}]}}\n\n\
                 data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"from chat\"}}}}]}}\n\n\
                 data: {{\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}],\"usage\":{{\"prompt_tokens\":12,\"completion_tokens\":5}}}}\n\n\
                 data: [DONE]\n\n"
            );
            let _ = &model;
            return Response::builder()
                .status(200)
                .header("content-type", "text/event-stream")
                .body(Body::from(sse))
                .unwrap();
        }
        return json_response(
            StatusCode::OK,
            &json!({
                "id": "chatcmpl-mock", "object": "chat.completion", "created": 1, "model": model,
                "choices": [{ "index": 0, "finish_reason": "stop",
                    "message": { "role": "assistant", "content": "hi from chat" } }],
                "usage": { "prompt_tokens": 12, "completion_tokens": 5, "total_tokens": 17 },
            }),
        );
    }
    // OpenAI Responses endpoint: reply in Responses shape (buffered) so messages→responses can be
    // exercised end-to-end. (The gateway forces stream=false upstream for the responses direction.)
    if path.ends_with("/responses") || path.ends_with("/responses/") {
        return json_response(
            StatusCode::OK,
            &json!({
                "id": "resp-mock", "object": "response", "created_at": 1, "model": model, "status": "completed",
                "output": [{ "type": "message", "role": "assistant",
                    "content": [{ "type": "output_text", "text": "hi from responses" }] }],
                "output_text": "hi from responses",
                "usage": { "input_tokens": 14, "output_tokens": 6, "total_tokens": 20 },
            }),
        );
    }
    if stream {
        // Anthropic streaming with a real text block, so the Anthropic→Responses incremental
        // transcoder (Codex client) has content to carry, not just usage bookkeeping.
        let sse = format!(
            "event: message_start\ndata: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_mock\",\"model\":\"{m}\",\"usage\":{{\"input_tokens\":10,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}}}}\n\nevent: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\nevent: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"hi from anthropic\"}}}}\n\nevent: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":0}}\n\nevent: message_delta\ndata: {{\"type\":\"message_delta\",\"usage\":{{\"output_tokens\":7}}}}\n\nevent: message_stop\ndata: {{\"type\":\"message_stop\"}}\n\n",
            m = model
        );
        Response::builder()
            .status(200)
            .header("content-type", "text/event-stream")
            .body(Body::from(sse))
            .unwrap()
    } else {
        json_response(
            StatusCode::OK,
            &json!({ "id":"msg_mock", "type":"message", "role":"assistant", "model":model, "content":[{"type":"text","text":"hi"}], "stop_reason":"end_turn", "usage":{"input_tokens":10,"output_tokens":7} }),
        )
    }
}
