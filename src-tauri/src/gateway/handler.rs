use axum::{
    body::to_bytes,
    extract::State,
    http::{Method, StatusCode},
    response::Response,
};
use bytes::Bytes;
use serde_json::{json, Value};
use std::sync::Arc;

use crate::store;

use super::forward::forward_and_finish;
use super::history_prep::prepare_responses_history;
use super::prepare::{gateway_token_error, parse_request_model, prepare_translation, upstream_headers};
use super::redact::{cap_text, redact_headers};
use super::responses_history::NativeResponsesHistoryContext;
use super::routing::{client_is_codex, resolve_routing};
use super::session::{codex_history_scope_for_session, request_session_id};
use super::sse::is_responses_compact_path;
use super::state::GatewayState;
use super::targets::{build_target, cross_wire_compact_error, endpoint_targets, error_response};

/// The localhost reverse-proxy handler. Mirrors proxy.js `handle`.
pub(super) async fn handle(State(st): State<Arc<GatewayState>>, req: axum::extract::Request) -> Response {
    let started = std::time::Instant::now();
    let (parts, body) = req.into_parts();
    let method = parts.method;
    let uri = parts.uri;
    let in_headers = parts.headers;
    let req_path = uri.path().to_string();
    let body_bytes = to_bytes(body, 64 * 1024 * 1024).await.unwrap_or_default();

    let config = store::read_config();

    if let Some(response) = gateway_token_error(&config, &in_headers) {
        return response;
    }

    let (parsed, requested_model) = parse_request_model(&in_headers, &body_bytes);

    let providers = config.get("providers").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    let active_id = config.get("activeProviderId").and_then(|v| v.as_str());
    let active_pid = providers
        .iter()
        .find(|p| p.get("id").and_then(|v| v.as_str()) == active_id)
        .or_else(|| providers.first())
        .and_then(|p| p.get("id").and_then(|v| v.as_str()))
        .map(|s| s.to_string());
    let known = match &active_pid {
        Some(pid) => st.known.lock().await.get(pid).cloned(),
        None => None,
    };

    let routing = match resolve_routing(requested_model.as_deref(), &config, known.as_ref()) {
        Some(r) => r,
        None => {
            st.log("warn", "request rejected: no provider configured");
            return error_response(StatusCode::BAD_GATEWAY, "CC Buddy: no provider configured. Add one in the app.", "api_error");
        }
    };
    let provider = match providers.iter().find(|p| p.get("id").and_then(|v| v.as_str()) == Some(routing.provider_id.as_str())) {
        Some(p) => p,
        None => return error_response(StatusCode::BAD_GATEWAY, "CC Buddy: no provider configured.", "api_error"),
    };
    let base_url = provider.get("baseUrl").and_then(|v| v.as_str()).unwrap_or("");
    let auth_token = provider.get("authToken").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let provider_name = provider
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or(routing.provider_id.as_str())
        .to_string();

    let need_rewrite = match (routing.client_facing_model.as_ref(), routing.outgoing_model.as_ref()) {
        (Some(c), Some(o)) => c != o,
        _ => false,
    };
    let mut out_body = body_bytes.clone();
    if let (Some(p0), Some(out_model)) = (parsed.as_ref(), routing.outgoing_model.as_ref()) {
        if Some(out_model) != requested_model.as_ref() {
            let mut p = p0.clone();
            p["model"] = json!(out_model);
            if let Ok(b) = serde_json::to_vec(&p) {
                out_body = Bytes::from(b);
            }
        }
    }

    let endpoint_pair = if method == Method::POST {
        endpoint_targets(base_url, &uri)
    } else {
        None
    };
    let (mut target, mut v1_fallback_target) = match endpoint_pair {
        Some(pair) => pair,
        None => match build_target(base_url, &uri) {
            Some(t) => (t, None),
            None => return error_response(StatusCode::BAD_GATEWAY, "CC Buddy: invalid provider baseUrl", "api_error"),
        },
    };
    let is_models_list = method == Method::GET && (req_path.ends_with("/v1/models") || req_path.ends_with("/v1/models/"));
    // Codex and Claude clients both GET /v1/models — tell them apart by client identity
    // so each gets its own family's default model list.
    let client_codex = client_is_codex(&in_headers);
    let is_head_root = method == Method::HEAD && req_path == "/";
    let is_count_tokens = method == Method::POST
        && (req_path.ends_with("/v1/messages/count_tokens") || req_path.ends_with("/v1/messages/count_tokens/"));

    // ---- protocol translation ----
    // When the client's wire protocol (inferred from the request path) differs from the provider's
    // declared protocol, translate the request into the provider's format and remember to translate
    // the response back. Same-protocol requests skip this entirely and keep the verbatim passthrough
    // fast path below (so Anthropic→Anthropic behavior is byte-for-byte unchanged). Streaming pairs
    // with an incremental transcoder (see protocol::stream::Transcoder) stream token-by-token; the
    // rest force the upstream buffered (stream=false) and synthesize the client SSE from the full
    // response.
    let client_wire = crate::protocol::Wire::from_request_path(&uri);
    let provider_wire =
        crate::protocol::Wire::from_provider(provider.get("protocol").and_then(|v| v.as_str()));
    let is_responses_compact = method == Method::POST && is_responses_compact_path(&req_path);
    if method == Method::POST {
        if let Some(response) = cross_wire_compact_error(&req_path, provider_wire) {
            return response;
        }
    }
    let request_session = parsed.as_ref().and_then(request_session_id);
    // Conversation history belongs to the client session, not the provider: users may switch the
    // active provider mid-turn and previous_response_id must still restore the same transcript.
    // Sessionless requests can use direct response-id lookup, but never call-id fallback because
    // call ids are routinely reused across unrelated agent runs.
    let codex_history_scope = codex_history_scope_for_session(request_session.as_deref());
    let allow_codex_call_fallback = request_session.is_some();
    let mut prepared_responses_request: Option<Value> = None;
    let mut native_responses_history: Option<NativeResponsesHistoryContext> = None;
    let mut history_localized = false;
    if let Some(response) = prepare_responses_history(
        &st, &parsed, &method, client_wire, provider_wire, &routing, &provider_name,
        &codex_history_scope, allow_codex_call_fallback, is_responses_compact,
        &mut out_body, &mut history_localized, &mut prepared_responses_request,
        &mut native_responses_history,
    )
    .await
    {
        return response;
    }
    let is_gemini_upstream = provider_wire == crate::protocol::Wire::OpenAiChat
        && routing.outgoing_model.as_deref().unwrap_or("").to_ascii_lowercase().contains("gemini");
    // translate ctx: (client wire, provider wire, client model, wanted stream, incremental,
    // request-scoped Responses tool metadata, full translated client request for history,
    // client-session history scope)
    // `incremental` = we can transcode the upstream stream event-by-event to the client (true
    // token-by-token). Otherwise we force the upstream buffered and synthesize the client response.
    let mut translate: Option<(crate::protocol::Wire, crate::protocol::Wire, String, bool, bool,
        crate::protocol::openai_responses::CodexToolContext,
        Value,
        String)> = None;
    if client_wire != provider_wire && method == Method::POST && !is_models_list && !is_count_tokens {
        if let Some(p) = parsed.as_ref() {
            if let Some(response) = prepare_translation(
                &st, p, &routing, client_wire, provider_wire, base_url, is_gemini_upstream,
                request_session.as_deref(), &prepared_responses_request, &codex_history_scope,
                &mut out_body, &mut target, &mut v1_fallback_target, &mut translate,
            )
            .await
            {
                return response;
            }
        }
    }

    // upstream headers (sanitized + provider token swapped in)
    let up_headers = upstream_headers(&in_headers, &translate, &auth_token);

    let ex_id = st.next_id();
    let ex_req_headers = redact_headers(&up_headers);
    let ex_req_body = cap_text(&out_body, 4 * 1024 * 1024);
    let original_target = target.clone();
    let ex_url = target.clone();
    // Client-side view of the exchange — what the gateway RECEIVED, before any translation — so
    // the monitor can show a protocol translation's exact before/after (inbound URL/headers/body
    // vs. the upstream URL/headers/body above). The body is duplicated only when a translation
    // applies; for passthrough, reqBody already IS the client body (modulo the model rewrite).
    let ex_translated = translate.as_ref().map(|t| format!("{} → {}", t.0.label(), t.1.label()));
    let ex_client_req = {
        let mut o = json!({
            "url": uri.path_and_query().map(|p| p.as_str().to_string()).unwrap_or_else(|| req_path.clone()),
            "headers": redact_headers(&in_headers),
        });
        if ex_translated.is_some() || history_localized {
            o["body"] = cap_text(&body_bytes, 1024 * 1024);
        }
        o
    };

    let insecure = config.get("insecureSkipVerify").and_then(|v| v.as_bool()).unwrap_or(false)
        && target.starts_with("https:");
    let client = if insecure { &st.client_insecure } else { &st.client };

    let rc = config.get("retry429").cloned().unwrap_or(json!({}));
    let retry_enabled = rc.get("enabled").map(|v| v.as_bool().unwrap_or(true)).unwrap_or(true);
    let retry_max = rc.get("max").and_then(|v| v.as_i64()).unwrap_or(3);
    let retry_base = rc.get("baseMs").and_then(|v| v.as_i64()).unwrap_or(500);

    forward_and_finish(
        &st, &config, client, method, target, v1_fallback_target, up_headers, out_body,
        original_target, ex_url, retry_enabled, retry_max, retry_base, provider_name, base_url,
        is_models_list, is_count_tokens, is_head_root, client_codex, parsed, ex_id, started,
        req_path, routing, ex_req_headers, ex_req_body, ex_client_req, ex_translated, translate,
        native_responses_history, request_session, is_gemini_upstream, need_rewrite, active_pid,
        client_wire,
    )
    .await
}
