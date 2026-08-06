use axum::{
    http::{HeaderMap, Method, StatusCode},
    response::Response,
};
use bytes::Bytes;
use serde_json::Value;
use std::sync::Arc;

use crate::store;

use super::finish::{finish_count_tokens, finish_head_root, finish_models_list};
use super::finish_buffered::finish_buffered;
use super::finish_translated::finish_translated;
use super::redact::HOP_BY_HOP_RES;
use super::responses_history::NativeResponsesHistoryContext;
use super::retry::forward_with_retry;
use super::routing::Routing;
use super::state::GatewayState;
use super::stream_passthrough::stream_passthrough;
use super::stream_transcode::stream_transcoded;
use super::targets::error_response;

#[allow(clippy::too_many_arguments)]
pub(super) async fn forward_and_finish(
    st: &Arc<GatewayState>,
    config: &Value,
    client: &reqwest::Client,
    method: Method,
    target: String,
    v1_fallback_target: Option<String>,
    up_headers: HeaderMap,
    out_body: Bytes,
    original_target: String,
    ex_url: String,
    retry_enabled: bool,
    retry_max: i64,
    retry_base: i64,
    provider_name: String,
    base_url: &str,
    is_models_list: bool,
    is_count_tokens: bool,
    is_head_root: bool,
    client_codex: bool,
    parsed: Option<Value>,
    ex_id: u64,
    started: std::time::Instant,
    req_path: String,
    routing: Routing,
    ex_req_headers: Value,
    ex_req_body: Value,
    ex_client_req: Value,
    ex_translated: Option<String>,
    translate: Option<(crate::protocol::Wire, crate::protocol::Wire, String, bool, bool,
        crate::protocol::openai_responses::CodexToolContext,
        Value,
        String)>,
    native_responses_history: Option<NativeResponsesHistoryContext>,
    request_session: Option<String>,
    is_gemini_upstream: bool,
    need_rewrite: bool,
    active_pid: Option<String>,
    client_wire: crate::protocol::Wire,
) -> Response {
    // Forward with the existing 429 retry plus one compatibility attempt at `/v1`. The first
    // response is retained until the fallback succeeds, so a failed fallback never masks the
    // upstream's original error.
    let (resp, used_v1_fallback, ex_url) = match forward_with_retry(
        st, client, &method, target, v1_fallback_target, &up_headers, &out_body,
        &original_target, ex_url, retry_enabled, retry_max, retry_base, &provider_name,
        is_models_list, is_count_tokens, config, client_codex, &parsed, ex_id, started,
        &req_path, &routing,
    )
    .await
    {
        Ok(forwarded) => forwarded,
        Err(response) => return response,
    };

    if used_v1_fallback {
        if let Some(saved) = store::migrate_provider_base_url_to_v1(&routing.provider_id, base_url) {
            st.log("info", format!("provider base URL updated with /v1 ({})", provider_name));
            st.emit("config:changed", saved);
        }
    }

    let status = resp.status();
    let ct = resp.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();

    if is_head_root && status.as_u16() == 404 {
        return finish_head_root(
            st, ex_id, started, method, req_path, provider_name, routing, ex_req_headers,
            ex_req_body, ex_client_req, ex_translated, ex_url,
        )
        .await;
    }

    let mut out_headers: Vec<(String, String)> = vec![];
    for (k, v) in resp.headers().iter() {
        let kn = k.as_str().to_ascii_lowercase();
        if HOP_BY_HOP_RES.contains(&kn.as_str()) {
            continue;
        }
        if let Ok(s) = v.to_str() {
            out_headers.push((k.as_str().to_string(), s.to_string()));
        }
    }

    // streaming SSE — rewrite model + sniff usage, line-buffered
    if ct.contains("text/event-stream") {
        // Incremental cross-protocol transcode: feed each upstream SSE line through a stateful
        // transcoder that emits the client protocol's events as they arrive (true token-by-token).
        if let Some((client_wire, provider_wire, tc, history_request, history_scope)) = translate
            .as_ref()
            .filter(|t| t.4)
            .and_then(|t| {
                // can_transcode_stream guarded `incremental`, so new() matches a wired pair.
                crate::protocol::stream::Transcoder::new_with_context(t.1, t.0, &t.2, t.5.clone()).map(|tc| (t.0, t.1, tc, t.6.clone(), t.7.clone()))
            })
        {
            return stream_transcoded(
                st, resp, tc, client_wire, provider_wire, history_request, history_scope, routing,
                request_session, is_gemini_upstream, status, ex_id, started, method, req_path,
                provider_name, out_headers, ex_req_headers, ex_req_body, ex_client_req,
                ex_translated, ex_url,
            );
        }
        return stream_passthrough(
            st, resp, need_rewrite, routing, method, req_path, provider_name, status, ex_id,
            started, out_headers, ex_req_headers, ex_req_body, ex_client_req, ex_translated,
            ex_url, native_responses_history, client_wire,
        );
    }

    // buffered (reqwest auto-decoded gzip/br/deflate)
    let buf = match resp.bytes().await {
        Ok(buf) => buf,
        Err(error) => {
            let message = format!("upstream response body transport error: {}", error);
            st.log("error", format!("{} ({})", message, provider_name));
            st.emit_request(
                ex_id,
                started,
                &method,
                &req_path,
                &provider_name,
                &routing,
                StatusCode::BAD_GATEWAY.as_u16(),
                None,
            );
            return error_response(StatusCode::BAD_GATEWAY, &format!("CC Buddy: {}", message), "api_error");
        }
    };

    if is_count_tokens {
        return finish_count_tokens(
            st, status, buf, out_headers, &parsed, ex_id, started, method, req_path,
            provider_name, routing, ex_req_headers, ex_req_body, ex_client_req, ex_translated,
            ex_url,
        )
        .await;
    }

    if is_models_list {
        return finish_models_list(
            st, status, buf, config, client_codex, active_pid, ex_id, started, method, req_path,
            provider_name, routing, ex_req_headers, ex_req_body, ex_client_req, ex_translated,
            ex_url,
        )
        .await;
    }

    // Translated response: decode the (buffered) upstream reply → IR → re-encode to the client's
    // protocol. We forced stream=false upstream, so the reply is always buffered here.
    if let Some((client_wire, provider_wire, ref client_model, wanted_stream, _incremental,
        ref tool_context, ref history_request, ref history_scope)) = translate {
        return finish_translated(
            st, buf, status, out_headers, client_wire, provider_wire, client_model, wanted_stream,
            tool_context, history_request, history_scope, &routing, request_session,
            is_gemini_upstream, ex_id, started, &method, &req_path, &provider_name,
            &ex_req_headers, &ex_req_body, &ex_client_req, &ex_translated, &ex_url,
        )
        .await;
    }

    finish_buffered(
        st, buf, &ct, native_responses_history, need_rewrite, routing, status, out_headers, ex_id,
        started, method, req_path, provider_name, ex_req_headers, ex_req_body, ex_client_req,
        ex_translated, ex_url,
    )
    .await
}
