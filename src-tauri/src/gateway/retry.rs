use axum::{
    body::Body,
    http::{HeaderMap, Method, StatusCode},
    response::Response,
};
use bytes::Bytes;
use serde_json::{json, Value};
use std::sync::Arc;

use super::models::synthesize_models;
use super::routing::Routing;
use super::state::GatewayState;
use super::targets::{error_response, json_response, retry_delay};

#[allow(clippy::too_many_arguments)]
pub(super) async fn forward_with_retry(
    st: &Arc<GatewayState>,
    client: &reqwest::Client,
    method: &Method,
    mut target: String,
    mut v1_fallback_target: Option<String>,
    up_headers: &HeaderMap,
    out_body: &Bytes,
    original_target: &str,
    mut ex_url: String,
    retry_enabled: bool,
    retry_max: i64,
    retry_base: i64,
    provider_name: &str,
    is_models_list: bool,
    is_count_tokens: bool,
    config: &Value,
    client_codex: bool,
    parsed: &Option<Value>,
    ex_id: u64,
    started: std::time::Instant,
    req_path: &str,
    routing: &Routing,
) -> Result<(reqwest::Response, bool, String), Response> {
    // Forward with the existing 429 retry plus one compatibility attempt at `/v1`. The first
    // response is retained until the fallback succeeds, so a failed fallback never masks the
    // upstream's original error.
    let mut attempt = 0i64;
    let mut tried_v1_fallback = false;
    let mut used_v1_fallback = false;
    let mut first_path_error: Option<reqwest::Response> = None;
    let resp = loop {
        let r = client
            .request(method.clone(), &target)
            .headers(up_headers.clone())
            .body(out_body.clone())
            .send()
            .await;
        match r {
            Ok(resp) => {
                if !tried_v1_fallback
                    && retry_enabled
                    && resp.status().as_u16() == 429
                    && attempt < retry_max
                {
                    let ra = resp.headers().get("retry-after").and_then(|v| v.to_str().ok()).map(|s| s.to_string());
                    let delay = retry_delay(ra.as_deref(), attempt, retry_base);
                    st.log("warn", format!("upstream 429 — retry {}/{} in {}ms ({})", attempt + 1, retry_max, delay, provider_name));
                    tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
                    attempt += 1;
                    continue;
                }
                if !tried_v1_fallback
                    && crate::protocol::should_try_v1_fallback(resp.status().as_u16())
                {
                    if let Some(fallback) = v1_fallback_target.take() {
                        first_path_error = Some(resp);
                        target = fallback;
                        ex_url = target.clone();
                        tried_v1_fallback = true;
                        attempt = 0;
                        continue;
                    }
                }
                if tried_v1_fallback {
                    if resp.status().is_success() {
                        used_v1_fallback = true;
                        ex_url = target.clone();
                        break resp;
                    }
                    ex_url = original_target.to_string();
                    break first_path_error.take().expect("v1 fallback keeps the first response");
                }
                break resp;
            }
            Err(e) => {
                if tried_v1_fallback {
                    if let Some(first) = first_path_error.take() {
                        ex_url = original_target.to_string();
                        st.log("info", format!("/v1 compatibility retry failed: {} ({})", e, provider_name));
                        break first;
                    }
                }
                if is_models_list {
                    st.emit_request(ex_id, started, &method, &req_path, &provider_name, &routing, 200, None);
                    return Err(json_response(StatusCode::OK, &synthesize_models(&config, client_codex)));
                }
                if is_count_tokens {
                    let est = crate::counttokens::estimate_input_tokens(parsed.as_ref().unwrap_or(&Value::Null));
                    st.emit_request(ex_id, started, &method, &req_path, &provider_name, &routing, 200, None);
                    return Err(Response::builder()
                        .status(200)
                        .header("content-type", "application/json")
                        .header("x-ccbud-tokens", "estimated")
                        .header("x-ccbud-upstream-status", "error")
                        .body(Body::from(serde_json::to_vec(&json!({ "input_tokens": est })).unwrap_or_default()))
                        .unwrap());
                }
                st.log("error", format!("upstream error: {}", e));
                st.emit_request(ex_id, started, &method, &req_path, &provider_name, &routing, 502, None);
                return Err(error_response(StatusCode::BAD_GATEWAY, &format!("CC Buddy upstream error: {}", e), "api_error"));
            }
        }
    };

    Ok((resp, used_v1_fallback, ex_url))
}
