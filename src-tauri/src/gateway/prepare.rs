use axum::{
    http::{HeaderMap, HeaderValue, StatusCode},
    response::Response,
};
use bytes::Bytes;
use serde_json::{json, Value};
use std::sync::Arc;

use super::redact::HOP_BY_HOP_REQ;
use super::responses_history::apply_responses_chat_request_controls;
use super::routing::Routing;
use super::signatures::apply_gemini_signature_fallback;
use super::state::GatewayState;
use super::targets::error_response;
use super::history_args::sanitize_provider_history_tool_arguments;

pub(super) fn gateway_token_error(config: &Value, in_headers: &HeaderMap) -> Option<Response> {
    // Optional local gateway token (defense in depth; already bound to localhost).
    if config.get("requireToken").and_then(|v| v.as_bool()).unwrap_or(false) {
        let token = config.get("gatewayToken").and_then(|v| v.as_str()).unwrap_or("");
        if !token.is_empty() {
            let auth = in_headers.get("authorization").and_then(|v| v.to_str().ok()).unwrap_or("");
            let bearer = auth
                .strip_prefix("Bearer ")
                .or_else(|| auth.strip_prefix("bearer "));
            let presented = bearer.unwrap_or_else(|| {
                in_headers.get("x-api-key").and_then(|v| v.to_str().ok()).unwrap_or("")
            });
            if presented != token {
                return Some(error_response(StatusCode::UNAUTHORIZED, "CC Buddy: invalid gateway token", "authentication_error"));
            }
        }
    }
    None
}

pub(super) fn parse_request_model(
    in_headers: &HeaderMap,
    body_bytes: &Bytes,
) -> (Option<Value>, Option<String>) {
    let is_json = in_headers
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.contains("application/json"))
        .unwrap_or(false);
    let mut parsed: Option<Value> = None;
    let mut requested_model: Option<String> = None;
    if !body_bytes.is_empty() && is_json {
        if let Ok(v) = serde_json::from_slice::<Value>(&body_bytes) {
            requested_model = v.get("model").and_then(|m| m.as_str()).map(|s| s.to_string());
            parsed = Some(v);
        }
    }
    (parsed, requested_model)
}

pub(super) fn upstream_headers(
    in_headers: &HeaderMap,
    translate: &Option<(crate::protocol::Wire, crate::protocol::Wire, String, bool, bool,
        crate::protocol::openai_responses::CodexToolContext,
        Value,
        String)>,
    auth_token: &str,
) -> HeaderMap {
    let mut up_headers = HeaderMap::new();
    for (k, v) in in_headers.iter() {
        let kn = k.as_str().to_ascii_lowercase();
        if HOP_BY_HOP_REQ.contains(&kn.as_str()) {
            continue;
        }
        up_headers.insert(k.clone(), v.clone());
    }
    up_headers.insert(axum::http::header::ACCEPT_ENCODING, HeaderValue::from_static("identity"));
    // A translated Anthropic upstream needs the anthropic-version header; OpenAI-family clients
    // (Codex) never send one.
    if translate.as_ref().map(|t| t.1) == Some(crate::protocol::Wire::Anthropic)
        && !up_headers.contains_key("anthropic-version")
    {
        up_headers.insert("anthropic-version", HeaderValue::from_static("2023-06-01"));
    }
    if !auth_token.is_empty() {
        // Auth via Authorization: Bearer only. Sending both authorization and x-api-key trips
        // providers that reject having the two auth headers present at once (matches provider_test).
        // Both inbound auth headers are already stripped by HOP_BY_HOP_REQ above.
        if let Ok(val) = HeaderValue::from_str(&format!("Bearer {}", auth_token)) {
            up_headers.insert(axum::http::header::AUTHORIZATION, val);
        }
    }
    up_headers
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn prepare_translation(
    st: &Arc<GatewayState>,
    p: &Value,
    routing: &Routing,
    client_wire: crate::protocol::Wire,
    provider_wire: crate::protocol::Wire,
    base_url: &str,
    is_gemini_upstream: bool,
    request_session: Option<&str>,
    prepared_responses_request: &Option<Value>,
    codex_history_scope: &str,
    out_body: &mut Bytes,
    target: &mut String,
    v1_fallback_target: &mut Option<String>,
    translate: &mut Option<(crate::protocol::Wire, crate::protocol::Wire, String, bool, bool,
        crate::protocol::openai_responses::CodexToolContext,
        Value,
        String)>,
) -> Option<Response> {
    let wanted_stream = p.get("stream").and_then(|v| v.as_bool()).unwrap_or(false);
    let incremental = wanted_stream
        && crate::protocol::can_transcode_stream(provider_wire, client_wire);
    let client_model = routing.client_facing_model.clone().unwrap_or_default();
    let outgoing = routing.outgoing_model.clone().unwrap_or_default();
    let request_for_translation = prepared_responses_request
        .clone()
        .unwrap_or_else(|| p.clone());
    let decoded = if client_wire == crate::protocol::Wire::OpenAiResponses {
        crate::protocol::openai_responses::decode_request_with_context(
            &request_for_translation,
        )
    } else {
        crate::protocol::decode_client_request(client_wire, &request_for_translation).map(
            |request| {
                (
                    request,
                    crate::protocol::openai_responses::CodexToolContext::default(),
                )
            },
        )
    };
    let (mut ir, tool_context) = match decoded {
        Ok(decoded) => decoded,
        Err(e) => {
            st.log(
                "warn",
                format!("client protocol decode ({:?}) failed: {}", client_wire, e),
            );
            return Some(error_response(
                StatusCode::BAD_REQUEST,
                &format!("CC Buddy invalid client request: {}", e),
                "invalid_request_error",
            ));
        }
    };
    // Neither the Anthropic nor the Responses client wire round-trips Gemini's thought
    // signature, so every translated client (Claude Code AND Codex) needs the session-cache
    // restore + documented fallback sentinel — Gemini 3 rejects current-turn function calls
    // without a signature (400).
    if is_gemini_upstream {
        st.thought_signatures.lock().await.restore(
            &routing.provider_id,
            request_session.as_deref(),
            &mut ir,
        );
    }
    // Repair after signature restoration so any call whose provider-visible payload changes
    // cannot accidentally regain a cached signature that authenticated different bytes.
    if provider_wire == crate::protocol::Wire::OpenAiChat {
        sanitize_provider_history_tool_arguments(&mut ir);
    }
    if is_gemini_upstream {
        apply_gemini_signature_fallback(&mut ir);
    }
    let translated_body = crate::protocol::encode_upstream_request(provider_wire, &ir, &outgoing, incremental);
    match translated_body {
        Ok(mut body) => {
            if client_wire == crate::protocol::Wire::OpenAiResponses
                && provider_wire == crate::protocol::Wire::OpenAiChat
            {
                apply_responses_chat_request_controls(&mut body, &request_for_translation);
            }
            // Ask OpenAI-family upstreams to include usage in the final stream chunk.
            if incremental && provider_wire == crate::protocol::Wire::OpenAiChat {
                body["stream_options"] = json!({ "include_usage": true });
            }
            if let Ok(b) = serde_json::to_vec(&body) {
                *out_body = Bytes::from(b);
            }
            // Send to the provider protocol's endpoint (drop the inbound path/query).
            *target = provider_wire.upstream_url(base_url);
            *v1_fallback_target = provider_wire.v1_fallback_url(base_url);
            *translate = Some((client_wire, provider_wire, client_model, wanted_stream, incremental,
                tool_context, request_for_translation, codex_history_scope.to_string()));
        }
        Err(e) => {
            st.log("error", format!("protocol translate ({:?}→{:?}) failed: {}", client_wire, provider_wire, e));
            return Some(error_response(StatusCode::BAD_GATEWAY, &format!("CC Buddy protocol translation failed: {}", e), "api_error"));
        }
    }
    None
}
