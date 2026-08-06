use axum::{
    body::Body,
    http::{Method, StatusCode},
    response::Response,
};
use bytes::Bytes;
use futures_util::StreamExt;
use serde_json::{json, Value};
use std::sync::Arc;

use crate::protocol::codex_history::ResponseOrigin;

use super::capture::StreamAbortGuard;
use super::monitor::UsageAcc;
use super::redact::{now_ms, vec_headers};
use super::routing::Routing;
use super::sse::responses_terminal_event;
use super::state::GatewayState;

#[allow(clippy::too_many_arguments)]
pub(super) fn stream_transcoded(
    st: &Arc<GatewayState>,
    resp: reqwest::Response,
    mut tc: crate::protocol::stream::Transcoder,
    client_wire: crate::protocol::Wire,
    provider_wire: crate::protocol::Wire,
    history_request: Value,
    history_scope: String,
    routing: Routing,
    request_session: Option<String>,
    is_gemini_upstream: bool,
    status: StatusCode,
    ex_id: u64,
    started: std::time::Instant,
    method: Method,
    req_path: String,
    provider_name: String,
    out_headers: Vec<(String, String)>,
    ex_req_headers: Value,
    ex_req_body: Value,
    ex_client_req: Value,
    ex_translated: Option<String>,
    ex_url: String,
) -> Response {
    let st2 = st.clone();
    let signature_provider_id = routing.provider_id.clone();
    let signature_session = request_session.clone();
    // Any Gemini-backed transcoded stream (Claude Code or Codex client) feeds the
    // signature cache; transcoders that don't track calls return an empty capture.
    let capture_thought_signatures = is_gemini_upstream;
    let status_code = status.as_u16();
    let ex_id2 = ex_id;
    let started2 = started;
    let xlabel = format!("{:?}->{:?}", provider_wire, client_wire);
    let up_res_headers = vec_headers(&out_headers);
    let mut guard = StreamAbortGuard::new(
        st.clone(), ex_id, started, method.clone(), req_path.clone(), provider_name.clone(),
        routing.clone(), status_code,
        json!({
            "id": ex_id, "ts": now_ms(), "method": method.as_str(), "path": req_path, "url": ex_url,
            "provider": provider_name, "requestedModel": routing.client_facing_model,
            "outgoingModel": routing.outgoing_model, "clientFacingModel": routing.client_facing_model,
            "status": status_code, "reqHeaders": ex_req_headers, "reqBody": ex_req_body,
            "clientReq": ex_client_req, "translated": ex_translated,
            "resHeaders": json!({ "content-type": "text/event-stream", "x-ccbud-translated": xlabel }),
            "resBody": json!({ "text": "", "bytes": 0, "truncated": 0 }),
        }),
        // raw upstream capture (pre-translation), so the monitor can show the exact
        // upstream stream next to the translated one the client received
        Some((status_code, up_res_headers)),
    );
    let method2 = method.clone();
    let path2 = req_path.clone();
    let pname2 = provider_name.clone();
    let routing2 = routing.clone();
    let body_stream = async_stream::stream! {
        let mut s = resp.bytes_stream();
        let mut buf = String::new();
        let mut history_recorded = false;
        while let Some(chunk) = s.next().await {
            match chunk {
                Ok(bytes) => {
                    let raw = String::from_utf8_lossy(&bytes);
                    guard.push_up(&raw);
                    buf.push_str(&raw);
                    let mut out = String::new();
                    while let Some(idx) = buf.find('\n') {
                        let line: String = buf.drain(..=idx).collect();
                        out.push_str(&tc.push(&line));
                    }
                    if capture_thought_signatures && tc.succeeded() {
                        let captured_calls = tc.captured_tool_calls();
                        st2.thought_signatures.lock().await.remember(
                            &signature_provider_id,
                            signature_session.as_deref(),
                            &captured_calls,
                        );
                    }
                    // Keep the guard current BEFORE suspending: once the terminal event is
                    // out, Codex closes the socket and the generator is dropped mid-await.
                    guard.push_res(&out);
                    guard.finished = tc.done();
                    if client_wire == crate::protocol::Wire::OpenAiResponses
                        && !history_recorded
                    {
                        if let Some(terminal) = responses_terminal_event(&out) {
                            history_recorded = true;
                            if terminal.kind.is_resumable() {
                                if let Some(response) = terminal.response.as_ref() {
                                    st2.codex_history
                                        .record_response_scoped_with_metadata(
                                            &history_scope,
                                            ResponseOrigin::Local,
                                            true,
                                            &history_request,
                                            response,
                                        )
                                        .await;
                                }
                            }
                        }
                    }
                    guard.usage = Some(UsageAcc {
                        input: tc.input_tokens(), output: tc.output_tokens(), saw: true, ..Default::default()
                    });
                    if !out.is_empty() {
                        yield Ok::<Bytes, std::io::Error>(Bytes::from(out));
                    }
                }
                Err(error) => {
                    let message = format!("upstream stream transport error: {}", error);
                    st2.log("error", format!("{} ({})", message, pname2));
                    buf.clear();
                    let out = tc.fail(&message);
                    guard.push_res(&out);
                    guard.finished = tc.done();
                    guard.usage = Some(UsageAcc {
                        input: tc.input_tokens(), output: tc.output_tokens(), saw: true, ..Default::default()
                    });
                    if !out.is_empty() {
                        yield Ok(Bytes::from(out));
                    }
                    break;
                }
            }
        }
        let mut tail = String::new();
        if !buf.is_empty() { tail.push_str(&tc.push(&buf)); }
        tail.push_str(&tc.finish());
        guard.finished = tc.done();
        guard.usage = Some(UsageAcc {
            input: tc.input_tokens(), output: tc.output_tokens(), saw: true, ..Default::default()
        });
        if capture_thought_signatures && tc.succeeded() {
            let captured_calls = tc.captured_tool_calls();
            st2.thought_signatures.lock().await.remember(
                &signature_provider_id,
                signature_session.as_deref(),
                &captured_calls,
            );
        }
        if !tail.is_empty() {
            guard.push_res(&tail);
            if client_wire == crate::protocol::Wire::OpenAiResponses
                && !history_recorded
            {
                if let Some(terminal) = responses_terminal_event(&tail) {
                    if terminal.kind.is_resumable() {
                        if let Some(response) = terminal.response.as_ref() {
                            st2.codex_history
                                .record_response_scoped_with_metadata(
                                    &history_scope,
                                    ResponseOrigin::Local,
                                    true,
                                    &history_request,
                                    response,
                                )
                                .await;
                        }
                    }
                }
            }
            yield Ok(Bytes::from(tail));
        }
        let mut usage = UsageAcc::default();
        usage.input = tc.input_tokens();
        usage.output = tc.output_tokens();
        usage.saw = true;
        st2.emit_request(ex_id2, started2, &method2, &path2, &pname2, &routing2, status_code, Some(&usage));
        let mut ex = guard.complete();
        ex["ms"] = json!(started2.elapsed().as_millis() as u64);
        st2.record_exchange(ex).await;
    };
    let mut builder = Response::builder()
        .status(status.as_u16())
        .header("content-type", "text/event-stream")
        .header("x-ccbud-translated", format!("{:?}->{:?}", provider_wire, client_wire));
    // Forward the upstream request id — clients (Claude Code) persist it as `requestId`,
    // which usage analytics use as half of the de-dup key.
    for (k, v) in &out_headers {
        if k == "request-id" || k == "x-request-id" {
            builder = builder.header(k, v);
        }
    }
    return builder.body(Body::from_stream(body_stream)).unwrap();
}
