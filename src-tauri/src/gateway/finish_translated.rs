use axum::{
    body::Body,
    http::{Method, StatusCode},
    response::Response,
};
use bytes::Bytes;
use serde_json::{json, Value};
use std::sync::Arc;

use crate::protocol::codex_history::ResponseOrigin;

use super::monitor::UsageAcc;
use super::redact::{cap_text, now_ms, vec_headers};
use super::routing::Routing;
use super::session::{response_tool_calls, response_tool_calls_with_client_ids};
use super::sse::{responses_terminal_event, responses_terminal_object, ResponsesTerminalKind};
use super::state::GatewayState;
use super::targets::error_response;

#[allow(clippy::too_many_arguments)]
pub(super) async fn finish_translated(
    st: &Arc<GatewayState>,
    buf: Bytes,
    status: StatusCode,
    out_headers: Vec<(String, String)>,
    client_wire: crate::protocol::Wire,
    provider_wire: crate::protocol::Wire,
    client_model: &str,
    wanted_stream: bool,
    tool_context: &crate::protocol::openai_responses::CodexToolContext,
    history_request: &Value,
    history_scope: &str,
    routing: &Routing,
    request_session: Option<String>,
    is_gemini_upstream: bool,
    ex_id: u64,
    started: std::time::Instant,
    method: &Method,
    req_path: &str,
    provider_name: &str,
    ex_req_headers: &Value,
    ex_req_body: &Value,
    ex_client_req: &Value,
    ex_translated: &Option<String>,
    ex_url: &str,
) -> Response {
// Translated response: decode the (buffered) upstream reply → IR → re-encode to the client's
// protocol. We forced stream=false upstream, so the reply is always buffered here.
    let text = String::from_utf8_lossy(&buf);
    if !status.is_success() {
        st.log("warn", format!("upstream {} on translated request ({})", status.as_u16(), provider_name));
        st.emit_request(ex_id, started, &method, &req_path, &provider_name, &routing, status.as_u16(), None);
        return error_response(
            StatusCode::from_u16(status.as_u16()).unwrap_or(StatusCode::BAD_GATEWAY),
            &format!("CC Buddy upstream error: {}", text.chars().take(400).collect::<String>()),
            "api_error",
        );
    }
    let ir = match crate::protocol::decode_upstream_response(provider_wire, &text) {
        Ok(ir) => ir,
        Err(e) => {
            st.log("error", format!("response translate ({:?}→{:?}) failed: {}", provider_wire, client_wire, e));
            st.emit_request(ex_id, started, &method, &req_path, &provider_name, &routing, 502, None);
            return error_response(StatusCode::BAD_GATEWAY, &format!("CC Buddy response translation failed: {}", e), "api_error");
        }
    };
    let mut usage = UsageAcc::default();
    if let Some(u) = ir.usage.as_ref() {
        usage.input = u.prompt_tokens as i64;
        usage.output = u.completion_tokens as i64;
        usage.saw = true;
    }
    let (ct_out, body_bytes, terminal_response) = if wanted_stream {
        let sse = if client_wire == crate::protocol::Wire::OpenAiResponses {
            crate::protocol::openai_responses::encode_response_sse_with_context(
                &ir,
                client_model,
                tool_context,
            )
        } else {
            crate::protocol::encode_client_response_sse(client_wire, &ir, client_model).unwrap_or_default()
        };
        let terminal = (client_wire == crate::protocol::Wire::OpenAiResponses)
            .then(|| responses_terminal_event(&sse))
            .flatten();
        ("text/event-stream", Bytes::from(sse), terminal)
    } else {
        let j = if client_wire == crate::protocol::Wire::OpenAiResponses {
            crate::protocol::openai_responses::encode_response_with_context(
                &ir,
                client_model,
                tool_context,
            )
        } else {
            crate::protocol::encode_client_response(client_wire, &ir, client_model).unwrap_or_else(|_| json!({}))
        };
        let terminal = (client_wire == crate::protocol::Wire::OpenAiResponses)
            .then(|| responses_terminal_object(&j))
            .flatten();
        ("application/json", Bytes::from(serde_json::to_vec(&j).unwrap_or_default()), terminal)
    };
    if is_gemini_upstream {
        let captured_calls = if client_wire == crate::protocol::Wire::OpenAiResponses {
            terminal_response
                .as_ref()
                .filter(|terminal| terminal.kind == ResponsesTerminalKind::Completed)
                .and_then(|terminal| terminal.response.as_ref())
                .map(|response| response_tool_calls_with_client_ids(&ir, response))
                .unwrap_or_default()
        } else {
            response_tool_calls(&ir)
        };
        if !captured_calls.is_empty() {
            st.thought_signatures.lock().await.remember(
                &routing.provider_id,
                request_session.as_deref(),
                &captured_calls,
            );
        }
    }
    if let Some(terminal) = terminal_response.as_ref() {
        if terminal.kind.is_resumable() {
            if let Some(response) = terminal.response.as_ref() {
                st.codex_history
                    .record_response_scoped_with_metadata(
                        history_scope,
                        ResponseOrigin::Local,
                        true,
                        history_request,
                        response,
                    )
                    .await;
            }
        }
    }
    st.emit_request(ex_id, started, &method, &req_path, &provider_name, &routing, status.as_u16(), Some(&usage));
    st.record_exchange(json!({
        "id": ex_id, "ts": now_ms(), "ms": started.elapsed().as_millis() as u64,
        "method": method.as_str(), "path": req_path, "url": ex_url,
        "provider": provider_name, "requestedModel": routing.client_facing_model,
        "outgoingModel": routing.outgoing_model, "clientFacingModel": routing.client_facing_model,
        "status": status.as_u16(), "reqHeaders": ex_req_headers, "reqBody": ex_req_body,
        "clientReq": ex_client_req, "translated": ex_translated,
        "upstreamRes": json!({ "status": status.as_u16(), "headers": vec_headers(&out_headers), "body": cap_text(&buf, 1024 * 1024) }),
        "resHeaders": json!({ "content-type": ct_out, "x-ccbud-translated": format!("{:?}->{:?}", provider_wire, client_wire) }),
        "resBody": cap_text(&body_bytes, 2 * 1024 * 1024),
    }))
    .await;
    let mut builder = Response::builder()
        .status(status.as_u16())
        .header("content-type", ct_out)
        .header("x-ccbud-translated", format!("{:?}->{:?}", provider_wire, client_wire));
    for (k, v) in &out_headers {
        if k == "request-id" || k == "x-request-id" {
            builder = builder.header(k, v);
        }
    }
    return builder.body(Body::from(body_bytes)).unwrap();
}
