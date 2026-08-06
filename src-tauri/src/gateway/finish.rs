use axum::{
    body::Body,
    http::{Method, StatusCode},
    response::Response,
};
use bytes::Bytes;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::Arc;


use super::models::{merge_models, synthesize_models};
use super::redact::now_ms;
use super::routing::Routing;
use super::state::GatewayState;

#[allow(clippy::too_many_arguments)]
pub(super) async fn finish_head_root(
    st: &Arc<GatewayState>,
    ex_id: u64,
    started: std::time::Instant,
    method: Method,
    req_path: String,
    provider_name: String,
    routing: Routing,
    ex_req_headers: Value,
    ex_req_body: Value,
    ex_client_req: Value,
    ex_translated: Option<String>,
    ex_url: String,
) -> Response {
    st.log("info", format!("HEAD / fallback: upstream 404 → gateway 200 ({})", provider_name));
    st.emit_request(ex_id, started, &method, &req_path, &provider_name, &routing, 200, None);
    st.record_exchange(json!({
        "id": ex_id, "ts": now_ms(), "ms": started.elapsed().as_millis() as u64,
        "method": method.as_str(), "path": req_path, "url": ex_url,
        "provider": provider_name, "requestedModel": routing.client_facing_model,
        "outgoingModel": routing.outgoing_model, "clientFacingModel": routing.client_facing_model,
        "status": 200, "reqHeaders": ex_req_headers, "reqBody": ex_req_body,
        "clientReq": ex_client_req, "translated": ex_translated,
        "resHeaders": json!({ "x-ccbud-fallback": "head-root-404-to-200", "x-ccbud-upstream-status": "404" }),
        "resBody": json!({ "text": "", "bytes": 0, "truncated": 0 }),
    }))
    .await;
    return Response::builder()
        .status(200)
        .header("x-ccbud-fallback", "head-root-404-to-200")
        .header("x-ccbud-upstream-status", "404")
        .body(Body::empty())
        .unwrap();
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn finish_count_tokens(
    st: &Arc<GatewayState>,
    status: StatusCode,
    buf: Bytes,
    out_headers: Vec<(String, String)>,
    parsed: &Option<Value>,
    ex_id: u64,
    started: std::time::Instant,
    method: Method,
    req_path: String,
    provider_name: String,
    routing: Routing,
    ex_req_headers: Value,
    ex_req_body: Value,
    ex_client_req: Value,
    ex_translated: Option<String>,
    ex_url: String,
) -> Response {
// count_tokens: pass the upstream's real number when it implements the endpoint; otherwise
// (404 / non-JSON / missing input_tokens) estimate locally so Claude Code's sizing keeps working.
    let upstream_ok = status.is_success()
        && serde_json::from_slice::<Value>(&buf)
            .ok()
            .and_then(|o| o.get("input_tokens").and_then(|v| v.as_i64()))
            .is_some();
    if upstream_ok {
        let mut builder = Response::builder().status(200).header("x-ccbud-tokens", "upstream");
        for (k, v) in &out_headers {
            builder = builder.header(k, v);
        }
        st.emit_request(ex_id, started, &method, &req_path, &provider_name, &routing, 200, None);
        return builder.body(Body::from(buf)).unwrap();
    }
    let est = crate::counttokens::estimate_input_tokens(parsed.as_ref().unwrap_or(&Value::Null));
    let ebody = serde_json::to_vec(&json!({ "input_tokens": est })).unwrap_or_default();
    st.emit_request(ex_id, started, &method, &req_path, &provider_name, &routing, 200, None);
    st.record_exchange(json!({
        "id": ex_id, "ts": now_ms(), "ms": started.elapsed().as_millis() as u64,
        "method": method.as_str(), "path": req_path, "url": ex_url,
        "provider": provider_name, "requestedModel": routing.client_facing_model,
        "outgoingModel": routing.outgoing_model, "clientFacingModel": routing.client_facing_model,
        "status": 200, "reqHeaders": ex_req_headers, "reqBody": ex_req_body,
        "clientReq": ex_client_req, "translated": ex_translated,
        "resHeaders": json!({ "x-ccbud-tokens": "estimated", "x-ccbud-upstream-status": status.as_u16().to_string() }),
        "resBody": json!({ "text": String::from_utf8_lossy(&ebody), "bytes": ebody.len(), "truncated": 0 }),
    }))
    .await;
    return Response::builder()
        .status(200)
        .header("content-type", "application/json")
        .header("x-ccbud-tokens", "estimated")
        .header("x-ccbud-upstream-status", status.as_u16().to_string())
        .body(Body::from(ebody))
        .unwrap();
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn finish_models_list(
    st: &Arc<GatewayState>,
    status: StatusCode,
    buf: Bytes,
    config: &Value,
    client_codex: bool,
    active_pid: Option<String>,
    ex_id: u64,
    started: std::time::Instant,
    method: Method,
    req_path: String,
    provider_name: String,
    routing: Routing,
    ex_req_headers: Value,
    ex_req_body: Value,
    ex_client_req: Value,
    ex_translated: Option<String>,
    ex_url: String,
) -> Response {
    let mut merged = None;
    if status.is_success() {
        if let Ok(o) = serde_json::from_slice::<Value>(&buf) {
            if let Some(data) = o.get("data").and_then(|d| d.as_array()) {
                if let Some(pid) = &active_pid {
                    let ids: HashSet<String> = data
                        .iter()
                        .filter_map(|m| m.get("id").and_then(|v| v.as_str()).map(|s| s.to_string()))
                        .collect();
                    if !ids.is_empty() {
                        st.known.lock().await.insert(pid.clone(), ids);
                    }
                }
                merged = Some(merge_models(&o, &config, client_codex));
            }
        }
    }
    let result = merged.unwrap_or_else(|| synthesize_models(&config, client_codex));
    let rbody = serde_json::to_vec(&result).unwrap_or_default();
    st.emit_request(ex_id, started, &method, &req_path, &provider_name, &routing, 200, None);
    st.record_exchange(json!({
        "id": ex_id, "ts": now_ms(), "ms": started.elapsed().as_millis() as u64,
        "method": method.as_str(), "path": req_path, "url": ex_url,
        "provider": provider_name, "requestedModel": routing.client_facing_model,
        "outgoingModel": routing.outgoing_model, "clientFacingModel": routing.client_facing_model,
        "status": 200, "reqHeaders": ex_req_headers, "reqBody": ex_req_body,
        "clientReq": ex_client_req, "translated": ex_translated,
        "resHeaders": json!({ "content-type": "application/json" }),
        "resBody": json!({ "text": String::from_utf8_lossy(&rbody), "bytes": rbody.len(), "truncated": 0 }),
    }))
    .await;
    return Response::builder()
        .status(200)
        .header("content-type", "application/json")
        .body(Body::from(rbody))
        .unwrap();
}
