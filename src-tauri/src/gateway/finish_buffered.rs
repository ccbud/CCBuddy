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
use super::responses_history::NativeResponsesHistoryContext;
use super::routing::Routing;
use super::sse::responses_terminal_object;
use super::state::GatewayState;

#[allow(clippy::too_many_arguments)]
pub(super) async fn finish_buffered(
    st: &Arc<GatewayState>,
    buf: Bytes,
    ct: &str,
    native_responses_history: Option<NativeResponsesHistoryContext>,
    need_rewrite: bool,
    routing: Routing,
    status: StatusCode,
    out_headers: Vec<(String, String)>,
    ex_id: u64,
    started: std::time::Instant,
    method: Method,
    req_path: String,
    provider_name: String,
    ex_req_headers: Value,
    ex_req_body: Value,
    ex_client_req: Value,
    ex_translated: Option<String>,
    ex_url: String,
) -> Response {
    let mut out_buf = buf.clone();
    let mut usage = UsageAcc::default();
    if ct.contains("application/json") || native_responses_history.is_some() {
        if let Ok(mut o) = serde_json::from_slice::<Value>(&buf) {
            if let Some(u) = o.get("usage").cloned() {
                usage.input += u.get("input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                usage.output += u.get("output_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                usage.cache_read += u.get("cache_read_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                usage.cache_creation += u.get("cache_creation_input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                usage.saw = true;
            }
            if status.is_success() {
                if let (Some(history), Some(terminal)) = (
                    native_responses_history.as_ref(),
                    responses_terminal_object(&o),
                ) {
                    if terminal.kind.is_resumable() {
                        st.codex_history
                            .record_response_scoped_with_metadata(
                                &history.scope,
                                ResponseOrigin::Native(history.provider_id.clone()),
                                history.materializable,
                                &history.request,
                                &o,
                            )
                            .await;
                    }
                }
            }
            if need_rewrite {
                if let Some(cf) = &routing.client_facing_model {
                    if o.get("model").and_then(|v| v.as_str()).is_some() {
                        o["model"] = json!(cf);
                        if let Ok(b) = serde_json::to_vec(&o) {
                            out_buf = Bytes::from(b);
                        }
                    }
                }
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
        "resHeaders": vec_headers(&out_headers), "resBody": cap_text(&out_buf, 2 * 1024 * 1024),
    }))
    .await;

    let mut builder = Response::builder().status(status.as_u16());
    for (k, v) in &out_headers {
        builder = builder.header(k, v);
    }
    builder.body(Body::from(out_buf)).unwrap()
}
