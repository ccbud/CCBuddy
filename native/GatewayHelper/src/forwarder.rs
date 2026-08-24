use crate::auth::inference_authorized;
use crate::config::{ProviderConfig, WireProtocol};
use crate::content_encoding::{
    decode_request_body, decode_response_body, has_encoded_body, ContentDecodeError,
};
use crate::error::GatewayError;
use crate::header_case::OriginalHeaderCases;
use crate::monitor::{AttemptCapture, CompletionCapture, StreamFailureCapture};
use crate::protocol::codex_history::ResponseOrigin;
use crate::protocol::{self, Wire};
use crate::retry::{RetryClass, RetryPolicy};
use crate::state::GatewayState;
use crate::upstream::{self, UpstreamResponse};
use axum::body::{to_bytes, Body};
use axum::http::{header, HeaderMap, HeaderValue, Method, StatusCode, Uri};
use axum::response::Response;
use bytes::Bytes;
use futures::StreamExt;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

pub async fn handle_inference(
    state: Arc<GatewayState>,
    request: axum::extract::Request,
) -> Response {
    let started = Instant::now();
    let mut request_guard = state.begin_request();
    let (mut parts, body) = request.into_parts();
    let original_cases = parts
        .extensions
        .remove::<OriginalHeaderCases>()
        .unwrap_or_default();

    if !inference_authorized(&parts.headers, &state.config) {
        request_guard.failure();
        return error_response(
            StatusCode::UNAUTHORIZED,
            "CC Buddy gateway authentication failed",
            "authentication_error",
        );
    }

    let body = match to_bytes(body, state.config.request_body_limit_bytes).await {
        Ok(body) => body,
        Err(_) => {
            request_guard.failure();
            return error_response(
                StatusCode::PAYLOAD_TOO_LARGE,
                "request body exceeds the configured limit",
                "invalid_request_error",
            );
        }
    };
    let is_inference =
        parts.method == Method::POST && Wire::from_request_endpoint(parts.uri.path()).is_some();
    let body = if is_inference {
        match decode_request_body(
            &mut parts.headers,
            body,
            state.config.request_body_limit_bytes,
        ) {
            Ok(body) => body,
            Err(error) => {
                request_guard.failure();
                let status = match error {
                    ContentDecodeError::CompressedTooLarge { .. }
                    | ContentDecodeError::DecompressedTooLarge { .. } => {
                        StatusCode::PAYLOAD_TOO_LARGE
                    }
                    ContentDecodeError::UnsupportedEncoding(_) => {
                        StatusCode::UNSUPPORTED_MEDIA_TYPE
                    }
                    ContentDecodeError::MalformedHeader
                    | ContentDecodeError::StackedEncoding
                    | ContentDecodeError::InvalidData { .. } => StatusCode::BAD_REQUEST,
                };
                return error_response(status, &error.to_string(), "invalid_request_error");
            }
        }
    } else {
        body
    };
    let parsed = (!body.is_empty())
        .then(|| serde_json::from_slice::<Value>(&body))
        .transpose();
    let parsed = match parsed {
        Ok(parsed) => parsed,
        Err(error) => {
            request_guard.failure();
            return error_response(
                StatusCode::BAD_REQUEST,
                &format!("invalid JSON request: {error}"),
                "invalid_request_error",
            );
        }
    };
    if is_inference && !matches!(parsed.as_ref(), Some(Value::Object(_))) {
        request_guard.failure();
        return error_response(
            StatusCode::BAD_REQUEST,
            "request body must be a JSON object",
            "invalid_request_error",
        );
    }
    let requested_model = parsed
        .as_ref()
        .and_then(|body| body.get("model"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let path = parts
        .uri
        .path_and_query()
        .map_or_else(|| parts.uri.path().to_string(), ToString::to_string);
    let monitor_id = state
        .monitor
        .begin(
            parts.method.as_str(),
            &path,
            requested_model.clone(),
            &parts.headers,
            &body,
        )
        .await;

    if let Some((status, client_headers, client_body)) = local_response(
        &state,
        &parts.method,
        &parts.uri,
        &parts.headers,
        parsed.as_ref(),
    ) {
        state
            .monitor
            .complete_local(
                monitor_id,
                status.as_u16(),
                started.elapsed().as_millis() as u64,
                &client_headers,
                &client_body,
            )
            .await;
        request_guard.success();
        return response_with_headers(status, client_headers, Body::from(client_body));
    }

    let provider_ids = state.config.ordered_provider_ids();
    let mut cursor = 0usize;
    let mut attempt_count = 0u32;
    let mut provider_attempts = 0u32;
    let mut last_failure: Option<Response> = None;
    let retry_policy = RetryPolicy {
        max_retries: if state.config.retry.enabled {
            state.config.retry.max_retries
        } else {
            0
        },
        base_delay: Duration::from_millis(state.config.retry.base_ms),
        max_delay: Duration::from_millis(state.config.retry.max_backoff_ms),
        max_retry_after: Duration::from_secs(30),
    };
    let max_provider_attempts = if state.config.failover.enabled {
        state.config.retry.max_retries.saturating_add(1)
    } else {
        1
    };

    while provider_attempts < max_provider_attempts {
        let Some(route) = state.router.select_from(&provider_ids, cursor).await else {
            break;
        };
        cursor = route.next_index();
        let Some(provider) = state.config.provider(route.provider_id()).cloned() else {
            route.release_neutral();
            continue;
        };
        provider_attempts = provider_attempts.saturating_add(1);
        let prepared = match prepare_request(
            &state,
            &parts.method,
            &parts.uri,
            &parts.headers,
            parsed.clone(),
            body.clone(),
            &provider,
        )
        .await
        {
            Ok(prepared) => prepared,
            Err(error) => {
                route.release_neutral();
                let message = error.error.to_string();
                let failure =
                    error_response(StatusCode::BAD_REQUEST, &message, "invalid_request_error");
                if state.config.failover.enabled
                    && error.class == PreparationFailureClass::ProviderLocal
                {
                    last_failure = Some(failure);
                    continue;
                }
                state
                    .monitor
                    .fail(monitor_id, started.elapsed().as_millis() as u64, message)
                    .await;
                request_guard.failure();
                return failure;
            }
        };

        let mut retries = 0u32;
        let mut target = prepared.target.clone();
        let mut v1_fallback = prepared.v1_fallback_target.clone();
        loop {
            attempt_count = attempt_count.saturating_add(1);
            state
                .monitor
                .attempt(
                    monitor_id,
                    AttemptCapture {
                        provider_id: provider.id.clone(),
                        provider_name: provider.name.clone(),
                        attempts: attempt_count,
                        translation: prepared.translation.clone(),
                        request_headers: prepared.headers.clone(),
                        request_body: prepared.body.clone(),
                    },
                )
                .await;
            let result = upstream::send_request(
                target.clone(),
                parts.method.clone(),
                prepared.headers.clone(),
                original_cases.clone(),
                prepared.body.clone(),
                Duration::from_secs(provider.timeout_seconds),
                state.config.insecure_skip_verify,
            )
            .await;

            let response = match result {
                Ok(response) => response,
                Err(error) => {
                    if state.config.failover.enabled {
                        route.failure().await;
                    } else {
                        route.release_neutral();
                    }
                    last_failure = Some(error_response(
                        StatusCode::BAD_GATEWAY,
                        &format!("provider {} failed: {error}", provider.name),
                        "api_error",
                    ));
                    break;
                }
            };

            let status = response.status();
            if protocol::should_try_v1_fallback(status.as_u16()) {
                if let Some(fallback) = v1_fallback.take() {
                    target = fallback;
                    drop(response);
                    continue;
                }
            }
            if crate::retry::is_failover_status(status) {
                if !state.config.failover.enabled && status == StatusCode::TOO_MANY_REQUESTS {
                    let retry_after = response
                        .headers()
                        .get(header::RETRY_AFTER)
                        .and_then(|value| value.to_str().ok())
                        .map(str::to_string);
                    if let Some(decision) = retry_policy.decision(
                        retries,
                        RetryClass::from_status(status),
                        retry_after.as_deref(),
                        SystemTime::now(),
                    ) {
                        retries = decision.retry_number;
                        drop(response);
                        tokio::time::sleep(decision.delay).await;
                        continue;
                    }
                }
                // Buffer failover responses through the same bounded decoder as every other
                // non-streaming response. This keeps compressed terminal 401/429/5xx bodies
                // readable by the client and monitor, and prevents compressed error envelopes
                // from bypassing the decompressed-size limit.
                let failure = match finish_response(
                    state.clone(),
                    monitor_id,
                    started,
                    &provider,
                    prepared,
                    response,
                )
                .await
                {
                    Ok(response) => response,
                    Err(error) => {
                        state
                            .monitor
                            .fail(
                                monitor_id,
                                started.elapsed().as_millis() as u64,
                                error.to_string(),
                            )
                            .await;
                        error_response(StatusCode::BAD_GATEWAY, &error.to_string(), "api_error")
                    }
                };
                if state.config.failover.enabled {
                    route.failure().await;
                } else {
                    route.release_neutral();
                }
                last_failure = Some(failure);
                break;
            }

            let final_response = match finish_response(
                state.clone(),
                monitor_id,
                started,
                &provider,
                prepared,
                response,
            )
            .await
            {
                Ok(response) => {
                    if status.is_success() {
                        route.success().await;
                    } else {
                        // Request-shape/client errors are terminal for this request but say
                        // nothing about provider health. This mirrors cc-switch's neutral permit
                        // release and prevents a bad client request from healing the circuit.
                        route.release_neutral();
                    }
                    response
                }
                Err(error) => {
                    if state.config.failover.enabled {
                        route.failure().await;
                    } else {
                        route.release_neutral();
                    }
                    state
                        .monitor
                        .fail(
                            monitor_id,
                            started.elapsed().as_millis() as u64,
                            error.to_string(),
                        )
                        .await;
                    let failure =
                        error_response(StatusCode::BAD_GATEWAY, &error.to_string(), "api_error");
                    if state.config.failover.enabled {
                        last_failure = Some(failure);
                        break;
                    }
                    request_guard.failure();
                    return failure;
                }
            };
            if final_response.status().is_success() {
                request_guard.success();
            } else {
                request_guard.failure();
            }
            return final_response;
        }
    }

    let all_circuits_unavailable =
        provider_attempts == 0 && !provider_ids.is_empty() && last_failure.is_none();
    let terminal_status = if all_circuits_unavailable {
        StatusCode::SERVICE_UNAVAILABLE
    } else {
        StatusCode::BAD_GATEWAY
    };
    let terminal_message = if all_circuits_unavailable {
        "all configured provider circuits are unavailable"
    } else {
        "all configured providers are unavailable"
    };
    let response = last_failure
        .unwrap_or_else(|| error_response(terminal_status, terminal_message, "api_error"));
    state
        .monitor
        .fail(
            monitor_id,
            started.elapsed().as_millis() as u64,
            terminal_message,
        )
        .await;
    request_guard.failure();
    response
}

fn local_response(
    state: &GatewayState,
    method: &Method,
    uri: &Uri,
    headers: &HeaderMap,
    parsed: Option<&Value>,
) -> Option<(StatusCode, HeaderMap, Vec<u8>)> {
    if *method == Method::HEAD && uri.path() == "/" {
        return Some((StatusCode::OK, HeaderMap::new(), Vec::new()));
    }

    let value = if crate::models::is_models_request(method, uri.path()) {
        crate::models::synthesize(&state.config, crate::models::client_is_codex(headers))
    } else if *method == Method::POST
        && matches!(
            uri.path().trim_end_matches('/'),
            "/messages/count_tokens" | "/v1/messages/count_tokens"
        )
    {
        json!({
            "input_tokens": crate::counttokens::estimate_input_tokens(
                parsed.unwrap_or(&Value::Null)
            )
        })
    } else {
        return None;
    };

    let mut response_headers = HeaderMap::new();
    response_headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    if uri
        .path()
        .trim_end_matches('/')
        .ends_with("/messages/count_tokens")
    {
        response_headers.insert("x-ccbud-tokens", HeaderValue::from_static("estimated"));
    }
    Some((
        StatusCode::OK,
        response_headers,
        serde_json::to_vec(&value).unwrap_or_default(),
    ))
}

#[derive(Clone)]
struct PreparedRequest {
    target: Uri,
    v1_fallback_target: Option<Uri>,
    headers: HeaderMap,
    body: Vec<u8>,
    client_wire: Option<Wire>,
    provider_wire: Wire,
    client_model: String,
    wanted_stream: bool,
    translation: Option<String>,
    history_scope: String,
    history_request: Option<Value>,
    tool_context: protocol::openai_responses::CodexToolContext,
    hosted_web_search: Option<crate::hosted_web_search::HostedWebSearchBridge>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PreparationFailureClass {
    ClientTerminal,
    ProviderLocal,
}

#[derive(Debug)]
struct PreparationFailure {
    class: PreparationFailureClass,
    error: GatewayError,
}

impl PreparationFailure {
    fn client_protocol(message: String) -> Self {
        Self {
            class: PreparationFailureClass::ClientTerminal,
            error: GatewayError::Protocol(message),
        }
    }

    fn provider(error: GatewayError) -> Self {
        Self {
            class: PreparationFailureClass::ProviderLocal,
            error,
        }
    }

    fn provider_protocol(message: String) -> Self {
        Self::provider(GatewayError::Protocol(message))
    }
}

async fn prepare_request(
    state: &Arc<GatewayState>,
    method: &Method,
    uri: &Uri,
    client_headers: &HeaderMap,
    parsed: Option<Value>,
    original_body: Bytes,
    provider: &ProviderConfig,
) -> Result<PreparedRequest, PreparationFailure> {
    let client_wire = (method == Method::POST)
        .then(|| Wire::from_request_endpoint(uri.path()))
        .flatten();
    let provider_wire = provider.protocol.as_ccbud_wire();
    let is_alpha_search = uri.path().trim_end_matches('/').ends_with("/alpha/search");
    if is_alpha_search && provider_wire != Wire::OpenAiResponses {
        return Err(PreparationFailure::provider_protocol(
            "cross-protocol Codex Alpha Search is not supported".into(),
        ));
    }
    if uri
        .path()
        .trim_end_matches('/')
        .ends_with("/responses/compact")
        && provider_wire != Wire::OpenAiResponses
    {
        return Err(PreparationFailure::provider(GatewayError::Protocol(
            "cross-protocol Responses compaction is not supported".into(),
        )));
    }
    let mut client_json = parsed;
    if let Some(Value::Object(body)) = client_json.as_mut() {
        body.retain(|key, _| !key.starts_with('_'));
    }
    let cross_wire = client_wire.is_some_and(|client| client != provider_wire);
    let hosted_web_search = if cross_wire
        && client_wire == Some(Wire::Anthropic)
        && provider_wire == Wire::OpenAiResponses
    {
        client_json
            .as_ref()
            .map(crate::hosted_web_search::HostedWebSearchBridge::from_anthropic_request)
            .transpose()
            .map_err(PreparationFailure::client_protocol)?
            .flatten()
    } else {
        None
    };
    if cross_wire
        && hosted_web_search.is_none()
        && client_json
            .as_ref()
            .is_some_and(request_uses_hosted_web_search)
    {
        return Err(PreparationFailure::provider_protocol(
            "cross-protocol hosted web search is not supported".into(),
        ));
    }
    let client_model = client_json
        .as_ref()
        .and_then(|body| body.get("model"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let outgoing_model = provider
        .resolve_model((!client_model.is_empty()).then_some(client_model.as_str()))
        .unwrap_or_else(|| provider.default_model.clone());
    let wanted_stream = client_json
        .as_ref()
        .and_then(|body| body.get("stream"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let history_scope = request_scope(client_headers, client_json.as_ref());

    if client_wire == Some(Wire::OpenAiResponses) && !is_alpha_search {
        if let Some(body) = client_json.as_mut() {
            let previous = body
                .get("previous_response_id")
                .and_then(Value::as_str)
                .map(str::to_string);
            let owner_mismatch = if let Some(previous) = previous.as_deref() {
                state
                    .history
                    .response_metadata(&history_scope, previous)
                    .await
                    .is_some_and(|metadata| match metadata.origin {
                        ResponseOrigin::Native(owner) => owner != provider.id,
                        ResponseOrigin::Local => false,
                    })
            } else {
                false
            };
            if provider_wire != Wire::OpenAiResponses || owner_mismatch {
                let resolution = state
                    .history
                    .materialize_request_scoped(&history_scope, !history_scope.is_empty(), body)
                    .await;
                if resolution.had_previous_response_id
                    && (!resolution.previous_found || !resolution.previous_materialized)
                {
                    return Err(PreparationFailure::provider(GatewayError::Protocol(
                        "previous_response_id cannot be materialized for this provider".into(),
                    )));
                }
            }
        }
    }

    // The generic Responses -> Anthropic stream transcoder cannot represent hosted server
    // tools without losing call/result pairing, citations, and server-tool usage. Ask the
    // upstream for a terminal response and synthesize the requested Anthropic SSE after the
    // dedicated hosted-search bridge has preserved those semantics.
    let upstream_stream = wanted_stream
        && hosted_web_search.is_none()
        && client_wire.is_some_and(|client| {
            !cross_wire || protocol::can_transcode_stream(provider_wire, client)
        });
    let mut tool_context = protocol::openai_responses::CodexToolContext::default();
    let body = match (client_wire, client_json.as_mut()) {
        (Some(client), Some(body)) if cross_wire => {
            let codec_body = hosted_web_search
                .as_ref()
                .map(|bridge| bridge.request_for_generic_codec(body));
            let codec_body = codec_body.as_ref().unwrap_or(body);
            let request = if client == Wire::OpenAiResponses {
                let (request, context) =
                    protocol::openai_responses::decode_request_with_context(codec_body)
                        .map_err(PreparationFailure::client_protocol)?;
                tool_context = context;
                request
            } else {
                protocol::decode_client_request(client, codec_body)
                    .map_err(PreparationFailure::client_protocol)?
            };
            let mut encoded = protocol::encode_upstream_request(
                provider_wire,
                &request,
                &outgoing_model,
                upstream_stream,
            )
            .map_err(PreparationFailure::provider_protocol)?;
            if let Some(bridge) = hosted_web_search.as_ref() {
                bridge
                    .apply_to_responses_request(body, &mut encoded)
                    .map_err(PreparationFailure::client_protocol)?;
            }
            serde_json::to_vec(&encoded)
                .map_err(|error| PreparationFailure::provider_protocol(error.to_string()))?
        }
        (Some(_), Some(body)) => {
            if !outgoing_model.is_empty() {
                body["model"] = Value::String(outgoing_model);
            }
            serde_json::to_vec(body)
                .map_err(|error| PreparationFailure::provider_protocol(error.to_string()))?
        }
        _ => original_body.to_vec(),
    };
    let target = build_target(provider, uri, client_wire).map_err(PreparationFailure::provider)?;
    let v1_fallback_target = build_v1_fallback_target(provider, uri, client_wire)
        .map_err(PreparationFailure::provider)?;
    let headers = upstream_headers(client_headers, provider, &target, cross_wire)
        .map_err(PreparationFailure::provider)?;
    let history_request = (client_wire == Some(Wire::OpenAiResponses) && !is_alpha_search)
        .then(|| client_json.clone())
        .flatten();
    Ok(PreparedRequest {
        target,
        v1_fallback_target,
        headers,
        body,
        client_wire,
        provider_wire,
        client_model,
        wanted_stream,
        translation: cross_wire.then(|| {
            format!(
                "{} → {}",
                client_wire.unwrap().label(),
                provider_wire.label()
            )
        }),
        history_scope,
        history_request,
        tool_context,
        hosted_web_search,
    })
}

fn request_uses_hosted_web_search(body: &Value) -> bool {
    let is_web_search_type = |value: &Value| {
        value
            .get("type")
            .and_then(Value::as_str)
            .is_some_and(|kind| kind == "web_search" || kind.starts_with("web_search_"))
    };
    if body
        .get("tools")
        .and_then(Value::as_array)
        .is_some_and(|tools| tools.iter().any(is_web_search_type))
        || body.get("tool_choice").is_some_and(is_web_search_type)
        || body
            .get("input")
            .and_then(Value::as_array)
            .is_some_and(|items| items.iter().any(is_web_search_type))
    {
        return true;
    }

    body.get("messages")
        .and_then(Value::as_array)
        .is_some_and(|messages| {
            messages.iter().any(|message| {
                message
                    .get("content")
                    .and_then(Value::as_array)
                    .is_some_and(|blocks| {
                        blocks.iter().any(|block| {
                            let kind = block.get("type").and_then(Value::as_str);
                            kind == Some("web_search_tool_result")
                                || (kind == Some("server_tool_use")
                                    && block.get("name").and_then(Value::as_str)
                                        == Some("web_search"))
                        })
                    })
            })
        })
}

async fn finish_response(
    state: Arc<GatewayState>,
    monitor_id: u64,
    started: Instant,
    provider: &ProviderConfig,
    prepared: PreparedRequest,
    response: UpstreamResponse,
) -> Result<Response, GatewayError> {
    let status = response.status();
    let upstream_headers = response.headers().clone();
    let cross_wire = prepared
        .client_wire
        .is_some_and(|client| client != prepared.provider_wire);
    let response_is_encoded = has_encoded_body(&upstream_headers).map_err(|error| {
        GatewayError::UpstreamTransient(format!(
            "provider returned an invalid content-encoding header: {error}"
        ))
    })?;
    if response.is_sse() && prepared.wanted_stream && response_is_encoded && cross_wire {
        return Err(GatewayError::UpstreamTransient(
            "cross-protocol streaming responses must not be compressed".into(),
        ));
    }
    let response = if status.is_success()
        && state.config.failover.enabled
        && response.is_sse()
        && prepared.wanted_stream
        && !response_is_encoded
    {
        prime_stream_for_failover(
            response,
            prepared.provider_wire,
            Duration::from_secs(if state.config.streaming_first_byte_timeout == 0 {
                provider.timeout_seconds.min(60)
            } else {
                state.config.streaming_first_byte_timeout
            }),
        )
        .await?
    } else {
        response
    };

    if !status.is_success() {
        let upstream_body = match read_response_body(
            response,
            state.config.response_body_limit_bytes,
            Duration::from_secs(provider.timeout_seconds),
        )
        .await
        {
            Ok(body) => body,
            Err(error) => {
                let (client_headers, client_body) =
                    error_response_content(&error.to_string(), "api_error");
                state
                    .monitor
                    .complete(
                        monitor_id,
                        CompletionCapture {
                            status: StatusCode::BAD_GATEWAY.as_u16(),
                            elapsed_ms: started.elapsed().as_millis() as u64,
                            upstream_headers,
                            upstream_body: Vec::new(),
                            client_headers,
                            client_body,
                        },
                    )
                    .await;
                return Err(error);
            }
        };
        let (decoded_headers, body) = match decode_buffered_upstream_response(
            &upstream_headers,
            upstream_body.clone(),
            state.config.response_body_limit_bytes,
        ) {
            Ok(decoded) => decoded,
            Err(error) => {
                let (client_headers, client_body) =
                    error_response_content(&error.to_string(), "api_error");
                state
                    .monitor
                    .complete(
                        monitor_id,
                        CompletionCapture {
                            status: StatusCode::BAD_GATEWAY.as_u16(),
                            elapsed_ms: started.elapsed().as_millis() as u64,
                            upstream_headers,
                            upstream_body: upstream_body.to_vec(),
                            client_headers,
                            client_body,
                        },
                    )
                    .await;
                return Err(error);
            }
        };
        let client_headers = filtered_response_headers(&decoded_headers, false);
        state
            .monitor
            .complete(
                monitor_id,
                CompletionCapture {
                    status: status.as_u16(),
                    elapsed_ms: started.elapsed().as_millis() as u64,
                    upstream_headers,
                    upstream_body: upstream_body.to_vec(),
                    client_headers: client_headers.clone(),
                    client_body: body.to_vec(),
                },
            )
            .await;
        return Ok(response_with_headers(
            status,
            client_headers,
            Body::from(body),
        ));
    }

    // A conforming Responses backend honors the `stream: false` set above. Some compatible
    // gateways still return SSE, however, so buffer it within the configured response limit
    // and recover only a valid terminal response. Never pass hosted WebSearch events through
    // the generic transcoder: it cannot preserve their protocol semantics.
    if response.is_sse() && prepared.hosted_web_search.is_some() {
        let raw_upstream_body = read_response_body(
            response,
            state.config.response_body_limit_bytes,
            Duration::from_secs(provider.timeout_seconds),
        )
        .await?;
        let response_json =
            crate::hosted_web_search::terminal_response_from_sse(&raw_upstream_body)
                .map_err(GatewayError::Protocol)?;
        let (client_body, content_type) =
            encode_hosted_web_search_response(&prepared, response_json)?;
        let mut client_headers = filtered_response_headers(&upstream_headers, true);
        client_headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
        client_headers.insert(
            "x-ccbud-translated",
            HeaderValue::from_static("openai-responses-to-anthropic-web-search"),
        );
        state
            .monitor
            .complete(
                monitor_id,
                CompletionCapture {
                    status: status.as_u16(),
                    elapsed_ms: started.elapsed().as_millis() as u64,
                    upstream_headers,
                    upstream_body: raw_upstream_body.to_vec(),
                    client_headers: client_headers.clone(),
                    client_body: client_body.clone(),
                },
            )
            .await;
        return Ok(response_with_headers(
            status,
            client_headers,
            Body::from(client_body),
        ));
    }

    if response.is_sse() && prepared.wanted_stream {
        if cross_wire {
            let client = prepared.client_wire.expect("cross-wire client");
            let transcoder = protocol::stream::Transcoder::new_with_context(
                prepared.provider_wire,
                client,
                &prepared.client_model,
                prepared.tool_context.clone(),
            )
            .ok_or_else(|| GatewayError::Protocol("stream pair is not supported".into()))?;
            return Ok(transcoded_stream_response(
                state,
                monitor_id,
                started,
                provider,
                prepared,
                upstream_headers,
                response,
                transcoder,
            ));
        }
        return Ok(passthrough_stream_response(
            state,
            monitor_id,
            started,
            provider,
            prepared,
            upstream_headers,
            response,
        ));
    }

    let raw_upstream_body = read_response_body(
        response,
        state.config.response_body_limit_bytes,
        Duration::from_secs(provider.timeout_seconds),
    )
    .await?;
    let (decoded_headers, upstream_body) = decode_buffered_upstream_response(
        &upstream_headers,
        raw_upstream_body.clone(),
        state.config.response_body_limit_bytes,
    )?;
    if state.config.failover.enabled {
        if let Some(message) = semantic_failure_message(&upstream_body) {
            return Err(GatewayError::UpstreamTransient(format!(
                "provider returned a 2xx failure envelope: {message}"
            )));
        }
    }
    if !cross_wire {
        if prepared.client_wire == Some(Wire::OpenAiResponses) {
            if let (Some(request), Ok(response)) = (
                prepared.history_request.as_ref(),
                serde_json::from_slice::<Value>(&upstream_body),
            ) {
                state
                    .history
                    .record_response_scoped_with_metadata(
                        &prepared.history_scope,
                        ResponseOrigin::Native(provider.id.clone()),
                        true,
                        request,
                        &response,
                    )
                    .await;
            }
        }
        let client_headers = filtered_response_headers(&decoded_headers, false);
        state
            .monitor
            .complete(
                monitor_id,
                CompletionCapture {
                    status: status.as_u16(),
                    elapsed_ms: started.elapsed().as_millis() as u64,
                    upstream_headers,
                    upstream_body: raw_upstream_body.to_vec(),
                    client_headers: client_headers.clone(),
                    client_body: upstream_body.to_vec(),
                },
            )
            .await;
        return Ok(response_with_headers(
            status,
            client_headers,
            Body::from(upstream_body),
        ));
    }

    let client_wire = prepared.client_wire.expect("cross-wire client");
    if client_wire == Wire::Anthropic && prepared.hosted_web_search.is_some() {
        let response_json: Value = serde_json::from_slice(&upstream_body)
            .map_err(|error| GatewayError::Protocol(format!("Responses parse: {error}")))?;
        let (client_body, content_type) =
            encode_hosted_web_search_response(&prepared, response_json)?;
        let mut client_headers = filtered_response_headers(&decoded_headers, true);
        client_headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
        client_headers.insert(
            "x-ccbud-translated",
            HeaderValue::from_static("openai-responses-to-anthropic-web-search"),
        );
        state
            .monitor
            .complete(
                monitor_id,
                CompletionCapture {
                    status: status.as_u16(),
                    elapsed_ms: started.elapsed().as_millis() as u64,
                    upstream_headers,
                    upstream_body: raw_upstream_body.to_vec(),
                    client_headers: client_headers.clone(),
                    client_body: client_body.clone(),
                },
            )
            .await;
        return Ok(response_with_headers(
            status,
            client_headers,
            Body::from(client_body),
        ));
    }
    let text = std::str::from_utf8(&upstream_body)
        .map_err(|error| GatewayError::Protocol(error.to_string()))?;
    let decoded = protocol::decode_upstream_response(prepared.provider_wire, text)
        .map_err(GatewayError::Protocol)?;
    let encoded = if client_wire == Wire::OpenAiResponses {
        protocol::openai_responses::encode_response_with_context(
            &decoded,
            &prepared.client_model,
            &prepared.tool_context,
        )
    } else {
        protocol::encode_client_response(client_wire, &decoded, &prepared.client_model)
            .map_err(GatewayError::Protocol)?
    };
    if client_wire == Wire::OpenAiResponses {
        if let Some(request) = prepared.history_request.as_ref() {
            state
                .history
                .record_response_scoped_with_metadata(
                    &prepared.history_scope,
                    ResponseOrigin::Local,
                    true,
                    request,
                    &encoded,
                )
                .await;
        }
    }
    let (client_body, content_type) = if prepared.wanted_stream {
        (
            if client_wire == Wire::OpenAiResponses {
                protocol::openai_responses::encode_response_sse_with_context(
                    &decoded,
                    &prepared.client_model,
                    &prepared.tool_context,
                )
                .into_bytes()
            } else {
                protocol::encode_client_response_sse(client_wire, &decoded, &prepared.client_model)
                    .map_err(GatewayError::Protocol)?
                    .into_bytes()
            },
            "text/event-stream",
        )
    } else {
        (
            serde_json::to_vec(&encoded)
                .map_err(|error| GatewayError::Protocol(error.to_string()))?,
            "application/json",
        )
    };
    let mut client_headers = filtered_response_headers(&decoded_headers, true);
    client_headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    client_headers.insert(
        "x-ccbud-translated",
        HeaderValue::from_str(&format!(
            "{}-to-{}",
            prepared.provider_wire.label(),
            client_wire.label()
        ))
        .unwrap_or_else(|_| HeaderValue::from_static("yes")),
    );
    state
        .monitor
        .complete(
            monitor_id,
            CompletionCapture {
                status: status.as_u16(),
                elapsed_ms: started.elapsed().as_millis() as u64,
                upstream_headers,
                upstream_body: raw_upstream_body.to_vec(),
                client_headers: client_headers.clone(),
                client_body: client_body.clone(),
            },
        )
        .await;
    Ok(response_with_headers(
        status,
        client_headers,
        Body::from(client_body),
    ))
}

fn encode_hosted_web_search_response(
    prepared: &PreparedRequest,
    response_json: Value,
) -> Result<(Vec<u8>, &'static str), GatewayError> {
    let bridge = prepared
        .hosted_web_search
        .as_ref()
        .ok_or_else(|| GatewayError::Protocol("hosted WebSearch bridge is not available".into()))?;
    let encoded = bridge
        .responses_to_anthropic(response_json, &prepared.client_model)
        .map_err(GatewayError::Protocol)?;
    if prepared.wanted_stream {
        Ok((
            crate::hosted_web_search::encode_anthropic_sse(&encoded).into_bytes(),
            "text/event-stream",
        ))
    } else {
        Ok((
            serde_json::to_vec(&encoded)
                .map_err(|error| GatewayError::Protocol(error.to_string()))?,
            "application/json",
        ))
    }
}

fn decode_buffered_upstream_response(
    upstream_headers: &HeaderMap,
    upstream_body: Bytes,
    limit: usize,
) -> Result<(HeaderMap, Bytes), GatewayError> {
    let mut decoded_headers = upstream_headers.clone();
    let decoded_body =
        decode_response_body(&mut decoded_headers, upstream_body, limit).map_err(|error| {
            match error {
                ContentDecodeError::CompressedTooLarge { .. }
                | ContentDecodeError::DecompressedTooLarge { .. } => {
                    GatewayError::ResponseTooLarge(limit)
                }
                error => GatewayError::UpstreamTransient(format!(
                    "provider returned an invalid compressed response: {error}"
                )),
            }
        })?;
    Ok((decoded_headers, decoded_body))
}

fn passthrough_stream_response(
    state: Arc<GatewayState>,
    monitor_id: u64,
    started: Instant,
    provider: &ProviderConfig,
    prepared: PreparedRequest,
    upstream_headers: HeaderMap,
    response: UpstreamResponse,
) -> Response {
    let status = response.status();
    let client_headers = filtered_response_headers(&upstream_headers, false);
    let completion_headers = client_headers.clone();
    let provider_id = provider.id.clone();
    let first_byte_timeout = Duration::from_secs(state.config.streaming_first_byte_timeout);
    let idle_timeout = Duration::from_secs(state.config.streaming_idle_timeout);
    let (sender, body) = streaming_body_channel();
    tokio::spawn(async move {
        let mut stream = response.bytes_stream();
        let mut captured = Vec::new();
        let mut terminal = ResponseTerminalScanner::default();
        let mut received_chunk = false;
        loop {
            let timeout = if received_chunk {
                idle_timeout
            } else {
                first_byte_timeout
            };
            let next = match poll_stream_chunk(&mut stream, &sender, timeout).await {
                StreamPoll::ClientClosed => {
                    state
                        .monitor
                        .fail_stream(
                            monitor_id,
                            StreamFailureCapture {
                                elapsed_ms: started.elapsed().as_millis() as u64,
                                error: "client disconnected before response stream completed"
                                    .into(),
                                upstream_headers,
                                upstream_body: captured.clone(),
                                client_headers: completion_headers,
                                client_body: captured,
                            },
                        )
                        .await;
                    return;
                }
                StreamPoll::TimedOut => {
                    let phase = if received_chunk { "idle" } else { "first byte" };
                    let message = format!(
                        "upstream stream {phase} timeout after {} seconds",
                        timeout.as_secs()
                    );
                    let _ = sender
                        .send(Err(std::io::Error::other(message.clone())))
                        .await;
                    state
                        .monitor
                        .fail_stream(
                            monitor_id,
                            StreamFailureCapture {
                                elapsed_ms: started.elapsed().as_millis() as u64,
                                error: message,
                                upstream_headers,
                                upstream_body: captured.clone(),
                                client_headers: completion_headers,
                                client_body: captured,
                            },
                        )
                        .await;
                    return;
                }
                StreamPoll::Next(next) => next,
            };
            match next {
                Some(Ok(bytes)) => {
                    received_chunk = true;
                    append_capture(&mut captured, &bytes);
                    terminal.push(&bytes);
                    if sender.send(Ok(bytes)).await.is_err() {
                        state
                            .monitor
                            .fail_stream(
                                monitor_id,
                                StreamFailureCapture {
                                    elapsed_ms: started.elapsed().as_millis() as u64,
                                    error: "client disconnected before response stream completed"
                                        .into(),
                                    upstream_headers,
                                    upstream_body: captured.clone(),
                                    client_headers: completion_headers,
                                    client_body: captured,
                                },
                            )
                            .await;
                        return;
                    }
                }
                Some(Err(error)) => {
                    let message = format!("upstream stream error: {error}");
                    let _ = sender
                        .send(Err(std::io::Error::other(message.clone())))
                        .await;
                    state
                        .monitor
                        .fail_stream(
                            monitor_id,
                            StreamFailureCapture {
                                elapsed_ms: started.elapsed().as_millis() as u64,
                                error: message,
                                upstream_headers,
                                upstream_body: captured.clone(),
                                client_headers: completion_headers,
                                client_body: captured,
                            },
                        )
                        .await;
                    return;
                }
                None => break,
            }
        }
        if prepared.client_wire == Some(Wire::OpenAiResponses) {
            if let (Some(request), Some(response)) =
                (prepared.history_request.as_ref(), terminal.finish())
            {
                state
                    .history
                    .record_response_scoped_with_metadata(
                        &prepared.history_scope,
                        ResponseOrigin::Native(provider_id),
                        true,
                        request,
                        &response,
                    )
                    .await;
            }
        }
        state
            .monitor
            .complete(
                monitor_id,
                CompletionCapture {
                    status: status.as_u16(),
                    elapsed_ms: started.elapsed().as_millis() as u64,
                    upstream_headers,
                    upstream_body: captured.clone(),
                    client_headers: completion_headers,
                    client_body: captured,
                },
            )
            .await;
    });
    response_with_headers(status, client_headers, body)
}

#[allow(clippy::too_many_arguments)]
fn transcoded_stream_response(
    state: Arc<GatewayState>,
    monitor_id: u64,
    started: Instant,
    _provider: &ProviderConfig,
    prepared: PreparedRequest,
    upstream_headers: HeaderMap,
    response: UpstreamResponse,
    mut transcoder: protocol::stream::Transcoder,
) -> Response {
    let status = response.status();
    let mut client_headers = filtered_response_headers(&upstream_headers, true);
    client_headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/event-stream"),
    );
    client_headers.insert("x-ccbud-translated", HeaderValue::from_static("stream"));
    let completion_headers = client_headers.clone();
    let first_byte_timeout = Duration::from_secs(state.config.streaming_first_byte_timeout);
    let idle_timeout = Duration::from_secs(state.config.streaming_idle_timeout);
    let (sender, body) = streaming_body_channel();
    tokio::spawn(async move {
        let mut stream = response.bytes_stream();
        let mut buffer = String::new();
        let mut upstream_capture = Vec::new();
        let mut client_capture = Vec::new();
        let mut terminal = ResponseTerminalScanner::default();
        let mut received_chunk = false;
        loop {
            let timeout = if received_chunk {
                idle_timeout
            } else {
                first_byte_timeout
            };
            let next = match poll_stream_chunk(&mut stream, &sender, timeout).await {
                StreamPoll::ClientClosed => {
                    state
                        .monitor
                        .fail_stream(
                            monitor_id,
                            StreamFailureCapture {
                                elapsed_ms: started.elapsed().as_millis() as u64,
                                error: "client disconnected before response stream completed"
                                    .into(),
                                upstream_headers,
                                upstream_body: upstream_capture,
                                client_headers: completion_headers,
                                client_body: client_capture,
                            },
                        )
                        .await;
                    return;
                }
                StreamPoll::TimedOut => {
                    let phase = if received_chunk { "idle" } else { "first byte" };
                    let message = format!(
                        "upstream stream {phase} timeout after {} seconds",
                        timeout.as_secs()
                    );
                    let output = transcoder.fail(&message);
                    if !output.is_empty() {
                        append_capture(&mut client_capture, output.as_bytes());
                        terminal.push(output.as_bytes());
                        let _ = sender.send(Ok(Bytes::from(output))).await;
                    }
                    state
                        .monitor
                        .fail_stream(
                            monitor_id,
                            StreamFailureCapture {
                                elapsed_ms: started.elapsed().as_millis() as u64,
                                error: message,
                                upstream_headers,
                                upstream_body: upstream_capture,
                                client_headers: completion_headers,
                                client_body: client_capture,
                            },
                        )
                        .await;
                    return;
                }
                StreamPoll::Next(next) => next,
            };
            match next {
                Some(Ok(bytes)) => {
                    received_chunk = true;
                    append_capture(&mut upstream_capture, &bytes);
                    buffer.push_str(&String::from_utf8_lossy(&bytes));
                    let mut output = String::new();
                    while let Some(index) = buffer.find('\n') {
                        let line: String = buffer.drain(..=index).collect();
                        output.push_str(&transcoder.push(&line));
                    }
                    if !output.is_empty() {
                        append_capture(&mut client_capture, output.as_bytes());
                        terminal.push(output.as_bytes());
                        if sender.send(Ok(Bytes::from(output))).await.is_err() {
                            state
                                .monitor
                                .fail_stream(
                                    monitor_id,
                                    StreamFailureCapture {
                                        elapsed_ms: started.elapsed().as_millis() as u64,
                                        error:
                                            "client disconnected before response stream completed"
                                                .into(),
                                        upstream_headers,
                                        upstream_body: upstream_capture,
                                        client_headers: completion_headers,
                                        client_body: client_capture,
                                    },
                                )
                                .await;
                            return;
                        }
                    }
                }
                Some(Err(error)) => {
                    let message = format!("upstream stream error: {error}");
                    let output = transcoder.fail(&message);
                    if !output.is_empty() {
                        append_capture(&mut client_capture, output.as_bytes());
                        terminal.push(output.as_bytes());
                        let _ = sender.send(Ok(Bytes::from(output))).await;
                    }
                    state
                        .monitor
                        .fail_stream(
                            monitor_id,
                            StreamFailureCapture {
                                elapsed_ms: started.elapsed().as_millis() as u64,
                                error: message,
                                upstream_headers,
                                upstream_body: upstream_capture,
                                client_headers: completion_headers,
                                client_body: client_capture,
                            },
                        )
                        .await;
                    return;
                }
                None => break,
            }
        }
        let mut tail = String::new();
        if !buffer.is_empty() {
            tail.push_str(&transcoder.push(&buffer));
        }
        tail.push_str(&transcoder.finish());
        if !tail.is_empty() {
            append_capture(&mut client_capture, tail.as_bytes());
            terminal.push(tail.as_bytes());
            if sender.send(Ok(Bytes::from(tail))).await.is_err() {
                state
                    .monitor
                    .fail_stream(
                        monitor_id,
                        StreamFailureCapture {
                            elapsed_ms: started.elapsed().as_millis() as u64,
                            error: "client disconnected before response stream completed".into(),
                            upstream_headers,
                            upstream_body: upstream_capture,
                            client_headers: completion_headers,
                            client_body: client_capture,
                        },
                    )
                    .await;
                return;
            }
        }
        if prepared.client_wire == Some(Wire::OpenAiResponses) {
            if let (Some(request), Some(response)) =
                (prepared.history_request.as_ref(), terminal.finish())
            {
                state
                    .history
                    .record_response_scoped_with_metadata(
                        &prepared.history_scope,
                        ResponseOrigin::Local,
                        true,
                        request,
                        &response,
                    )
                    .await;
            }
        }
        state
            .monitor
            .complete(
                monitor_id,
                CompletionCapture {
                    status: status.as_u16(),
                    elapsed_ms: started.elapsed().as_millis() as u64,
                    upstream_headers,
                    upstream_body: upstream_capture,
                    client_headers: completion_headers,
                    client_body: client_capture,
                },
            )
            .await;
    });
    response_with_headers(status, client_headers, body)
}

enum StreamPoll {
    ClientClosed,
    TimedOut,
    Next(Option<Result<Bytes, std::io::Error>>),
}

async fn poll_stream_chunk<S>(
    stream: &mut S,
    sender: &tokio::sync::mpsc::Sender<Result<Bytes, std::io::Error>>,
    timeout: Duration,
) -> StreamPoll
where
    S: futures::Stream<Item = Result<Bytes, std::io::Error>> + Unpin,
{
    tokio::select! {
        biased;
        _ = sender.closed() => StreamPoll::ClientClosed,
        next = stream.next() => StreamPoll::Next(next),
        _ = tokio::time::sleep(timeout), if !timeout.is_zero() => StreamPoll::TimedOut,
    }
}

fn streaming_body_channel() -> (
    tokio::sync::mpsc::Sender<Result<Bytes, std::io::Error>>,
    Body,
) {
    let (sender, receiver) = tokio::sync::mpsc::channel(8);
    let stream = futures::stream::unfold(receiver, |mut receiver| async move {
        receiver.recv().await.map(|item| (item, receiver))
    });
    (sender, Body::from_stream(stream))
}

fn build_target(
    provider: &ProviderConfig,
    uri: &Uri,
    client_wire: Option<Wire>,
) -> Result<Uri, GatewayError> {
    let target = if client_wire.is_some() {
        if uri.path().trim_end_matches('/').ends_with("/alpha/search") {
            alpha_search_upstream_url(&provider.base_url, uri.query())?
        } else {
            let mut target = provider
                .protocol
                .as_ccbud_wire()
                .upstream_url_for_request(&provider.base_url, uri.path());
            if let Some(query) = uri.query() {
                target.push('?');
                target.push_str(query);
            }
            target
        }
    } else {
        collapse_overlapping_path(&provider.base_url, uri)
    };
    target
        .parse::<Uri>()
        .map_err(|error| GatewayError::Http(format!("invalid upstream target: {error}")))
}

fn build_v1_fallback_target(
    provider: &ProviderConfig,
    uri: &Uri,
    client_wire: Option<Wire>,
) -> Result<Option<Uri>, GatewayError> {
    if client_wire.is_none() {
        return Ok(None);
    }
    if uri.path().trim_end_matches('/').ends_with("/alpha/search") {
        return Ok(None);
    }
    let Some(mut target) = provider
        .protocol
        .as_ccbud_wire()
        .v1_fallback_url_for_request(&provider.base_url, uri.path())
    else {
        return Ok(None);
    };
    if let Some(query) = uri.query() {
        target.push('?');
        target.push_str(query);
    }
    target
        .parse::<Uri>()
        .map(Some)
        .map_err(|error| GatewayError::Http(format!("invalid v1 fallback target: {error}")))
}

fn alpha_search_upstream_url(
    base_url: &str,
    request_query: Option<&str>,
) -> Result<String, GatewayError> {
    let trimmed = base_url.trim();
    let parsed = url::Url::parse(trimmed)
        .map_err(|error| GatewayError::Http(format!("invalid Alpha Search base URL: {error}")))?;
    let without_fragment = trimmed
        .split_once('#')
        .map_or(trimmed, |(head, _fragment)| head);
    let (url_without_query, base_query) = without_fragment
        .split_once('?')
        .map_or((without_fragment, None), |(head, query)| {
            (head, Some(query))
        });
    let url_without_query = url_without_query.trim_end_matches('/');
    let parsed_path = parsed.path().trim_end_matches('/');

    let mut target = if let Some(suffix) = ["/responses/compact", "/responses"]
        .into_iter()
        .find(|suffix| parsed_path.ends_with(suffix))
    {
        let prefix_length = url_without_query
            .len()
            .checked_sub(suffix.len())
            .ok_or_else(|| GatewayError::Http("invalid Alpha Search base URL".into()))?;
        format!("{}/alpha/search", &url_without_query[..prefix_length])
    } else if parsed_path.is_empty() {
        format!("{url_without_query}/v1/alpha/search")
    } else {
        format!("{url_without_query}/alpha/search")
    };

    let base_query = base_query.filter(|query| !query.is_empty());
    let request_query = request_query.filter(|query| !query.is_empty());
    match (base_query, request_query) {
        (Some(base), Some(request)) => target.push_str(&format!("?{base}&{request}")),
        (Some(base), None) => target.push_str(&format!("?{base}")),
        (None, Some(request)) => target.push_str(&format!("?{request}")),
        (None, None) => {}
    }
    Ok(target)
}

fn collapse_overlapping_path(base_url: &str, uri: &Uri) -> String {
    let base = base_url.trim_end_matches('/');
    let base_path = url::Url::parse(base_url)
        .ok()
        .map(|url| url.path().trim_end_matches('/').to_string())
        .unwrap_or_default();
    let path = if base_path.is_empty() || base_path == "/" {
        uri.path()
    } else if uri.path() == base_path {
        ""
    } else {
        uri.path()
            .strip_prefix(&base_path)
            .filter(|rest| rest.starts_with('/'))
            .unwrap_or(uri.path())
    };
    match uri.query() {
        Some(query) => format!("{base}{path}?{query}"),
        None => format!("{base}{path}"),
    }
}

fn upstream_headers(
    inbound: &HeaderMap,
    provider: &ProviderConfig,
    target: &Uri,
    translated: bool,
) -> Result<HeaderMap, GatewayError> {
    let mut output = HeaderMap::new();
    for (name, value) in inbound {
        let lower = name.as_str();
        if is_hop_by_hop(lower)
            || matches!(
                lower,
                "authorization" | "x-api-key" | "x-goog-api-key" | "host" | "content-length"
            )
        {
            continue;
        }
        output.append(name, value.clone());
    }
    output.insert(
        header::ACCEPT_ENCODING,
        HeaderValue::from_static("identity"),
    );
    if translated {
        output.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        );
    }
    if let Some(authority) = target.authority() {
        output.insert(
            header::HOST,
            HeaderValue::from_str(authority.as_str())
                .map_err(|error| GatewayError::Http(error.to_string()))?,
        );
    }
    if !provider.auth_token.is_empty() {
        match provider.protocol {
            WireProtocol::Anthropic => {
                output.insert(
                    "x-api-key",
                    HeaderValue::from_str(&provider.auth_token)
                        .map_err(|error| GatewayError::Http(error.to_string()))?,
                );
                output
                    .entry("anthropic-version")
                    .or_insert(HeaderValue::from_static("2023-06-01"));
            }
            WireProtocol::OpenaiChat | WireProtocol::OpenaiResponses => {
                output.insert(
                    header::AUTHORIZATION,
                    HeaderValue::from_str(&format!("Bearer {}", provider.auth_token))
                        .map_err(|error| GatewayError::Http(error.to_string()))?,
                );
            }
        }
    }
    for (name, value) in &provider.headers {
        let name = http::header::HeaderName::from_bytes(name.as_bytes())
            .map_err(|error| GatewayError::Http(error.to_string()))?;
        let value =
            HeaderValue::from_str(value).map_err(|error| GatewayError::Http(error.to_string()))?;
        output.insert(name, value);
    }
    Ok(output)
}

fn filtered_response_headers(upstream: &HeaderMap, transformed: bool) -> HeaderMap {
    let mut output = HeaderMap::new();
    for (name, value) in upstream {
        if is_hop_by_hop(name.as_str())
            || name == header::CONTENT_LENGTH
            || (transformed && name == header::CONTENT_ENCODING)
        {
            continue;
        }
        output.append(name, value.clone());
    }
    output
}

fn is_hop_by_hop(name: &str) -> bool {
    matches!(
        name,
        "connection"
            | "proxy-connection"
            | "keep-alive"
            | "proxy-authenticate"
            | "proxy-authorization"
            | "te"
            | "trailer"
            | "transfer-encoding"
            | "upgrade"
    )
}

fn request_scope(headers: &HeaderMap, body: Option<&Value>) -> String {
    for name in [
        "session_id",
        "x-session-id",
        "conversation_id",
        "x-conversation-id",
    ] {
        if let Some(value) = headers.get(name).and_then(|value| value.to_str().ok()) {
            let value = value.trim();
            if !value.is_empty() && value.len() <= 512 {
                return value.to_string();
            }
        }
    }
    body.and_then(|body| {
        ["session_id", "conversation_id"]
            .iter()
            .find_map(|key| body.get(key).and_then(Value::as_str))
    })
    .filter(|value| !value.trim().is_empty() && value.len() <= 512)
    .unwrap_or_default()
    .to_string()
}

fn semantic_failure_message(bytes: &[u8]) -> Option<String> {
    let value: Value = serde_json::from_slice(bytes).ok()?;
    semantic_failure_value(&value)
}

fn semantic_failure_value(value: &Value) -> Option<String> {
    let status = value.get("status").and_then(Value::as_str);
    let failed_status = matches!(status, Some("failed" | "cancelled"));
    let error = value
        .get("error")
        .filter(|error| !error.is_null())
        .or_else(|| (value.get("type").and_then(Value::as_str) == Some("error")).then_some(value));
    if !failed_status && error.is_none() {
        return None;
    }
    let error = error.unwrap_or(value);
    let kind = error
        .get("type")
        .and_then(Value::as_str)
        .or_else(|| error.get("code").and_then(Value::as_str))
        .or(status)
        .unwrap_or("upstream_error");
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .or_else(|| error.as_str())
        .unwrap_or("response generation failed");
    Some(format!("{kind}: {message}"))
}

async fn prime_stream_for_failover(
    response: UpstreamResponse,
    provider_wire: Wire,
    timeout: Duration,
) -> Result<UpstreamResponse, GatewayError> {
    if provider_wire != Wire::OpenAiResponses {
        return response.prime_stream(timeout).await;
    }

    const MAX_PRIME_BYTES: usize = 256 * 1_024;
    let status = response.status();
    let headers = response.headers().clone();
    let mut stream = response.bytes_stream();
    let mut replay = Vec::new();
    let mut replay_bytes = 0usize;
    let mut parse_buffer = String::new();

    loop {
        let next = tokio::time::timeout(timeout, stream.next())
            .await
            .map_err(|_| {
                GatewayError::UpstreamTransient(format!(
                    "Responses stream produced no semantic output within {} seconds",
                    timeout.as_secs()
                ))
            })?;
        let Some(chunk) = next else {
            if let Some(outcome) = inspect_responses_document(&parse_buffer) {
                outcome.map_err(GatewayError::UpstreamTransient)?;
                return Ok(replay_stream(status, headers, replay, stream));
            }
            if let Some(outcome) = inspect_responses_stream_block(parse_buffer.trim()) {
                outcome.map_err(GatewayError::UpstreamTransient)?;
                return Ok(replay_stream(status, headers, replay, stream));
            }
            return Err(GatewayError::UpstreamTransient(
                "Responses stream ended before semantic output".into(),
            ));
        };
        let chunk = chunk.map_err(|error| {
            GatewayError::UpstreamTransient(format!(
                "failed while priming Responses stream: {error}"
            ))
        })?;
        replay_bytes = replay_bytes.saturating_add(chunk.len());
        parse_buffer.push_str(&String::from_utf8_lossy(&chunk));
        replay.push(chunk);

        if let Some(outcome) = inspect_responses_document(&parse_buffer) {
            outcome.map_err(GatewayError::UpstreamTransient)?;
            return Ok(replay_stream(status, headers, replay, stream));
        }
        while let Some(block) = take_sse_block(&mut parse_buffer) {
            if let Some(outcome) = inspect_responses_stream_block(&block) {
                outcome.map_err(GatewayError::UpstreamTransient)?;
                return Ok(replay_stream(status, headers, replay, stream));
            }
        }
        if replay_bytes >= MAX_PRIME_BYTES {
            return Ok(replay_stream(status, headers, replay, stream));
        }
    }
}

fn replay_stream(
    status: StatusCode,
    headers: HeaderMap,
    replay: Vec<Bytes>,
    stream: std::pin::Pin<Box<dyn futures::Stream<Item = Result<Bytes, std::io::Error>> + Send>>,
) -> UpstreamResponse {
    UpstreamResponse::streamed(
        status,
        headers,
        futures::stream::iter(replay.into_iter().map(Ok)).chain(stream),
    )
}

fn inspect_responses_document(buffer: &str) -> Option<Result<(), String>> {
    let trimmed = buffer.trim();
    if !matches!(trimmed.as_bytes().first(), Some(b'{') | Some(b'[')) {
        return None;
    }
    let value: Value = serde_json::from_str(trimmed).ok()?;
    Some(match semantic_failure_value(&value) {
        Some(message) => Err(format!(
            "Responses upstream returned a 2xx failure: {message}"
        )),
        None => Ok(()),
    })
}

fn inspect_responses_stream_block(block: &str) -> Option<Result<(), String>> {
    if block.trim().is_empty() {
        return None;
    }
    let mut named_event = None;
    let mut data = Vec::new();
    for line in block.lines() {
        let line = line.trim_end_matches('\r');
        if let Some(value) = line.strip_prefix("event:") {
            named_event = Some(value.trim());
        } else if let Some(value) = line.strip_prefix("data:") {
            data.push(value.trim_start());
        }
    }
    if data.is_empty() {
        return None;
    }
    let data = data.join("\n");
    if data.trim() == "[DONE]" {
        return Some(Ok(()));
    }
    let value: Value = match serde_json::from_str(&data) {
        Ok(value) => value,
        Err(_) if named_event == Some("error") => {
            return Some(Err(format!("Responses upstream error: {}", data.trim())));
        }
        Err(_) => return None,
    };
    let event = named_event
        .filter(|event| !event.is_empty())
        .or_else(|| value.get("type").and_then(Value::as_str))
        .unwrap_or_default();
    let response = value.get("response").unwrap_or(&value);
    if let Some(message) = semantic_failure_value(response) {
        return Some(Err(format!("Responses upstream {message}")));
    }
    if matches!(event, "response.failed" | "error") {
        return Some(Err("Responses upstream failed before output".into()));
    }
    match event {
        "" | "response.created" | "response.in_progress" | "response.queued" => None,
        _ => Some(Ok(())),
    }
}

fn take_sse_block(buffer: &mut String) -> Option<String> {
    let delimiter = match (buffer.find("\n\n"), buffer.find("\r\n\r\n")) {
        (Some(lf), Some(crlf)) if lf <= crlf => (lf, 2),
        (Some(_), Some(crlf)) => (crlf, 4),
        (Some(lf), None) => (lf, 2),
        (None, Some(crlf)) => (crlf, 4),
        (None, None) => return None,
    };
    Some(buffer.drain(..delimiter.0 + delimiter.1).collect())
}

#[cfg(test)]
fn responses_terminal_event(bytes: &[u8]) -> Option<Value> {
    let mut scanner = ResponseTerminalScanner::default();
    scanner.push(bytes);
    scanner.finish()
}

#[derive(Default)]
struct ResponseTerminalScanner {
    buffer: Vec<u8>,
    terminal: Option<Value>,
}

impl ResponseTerminalScanner {
    fn push(&mut self, bytes: &[u8]) {
        const MAX_EVENT_LINE_BYTES: usize = 32 * 1_024 * 1_024;
        if self.buffer.len().saturating_add(bytes.len()) > MAX_EVENT_LINE_BYTES {
            self.buffer.clear();
            return;
        }
        self.buffer.extend_from_slice(bytes);
        while let Some(index) = self.buffer.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=index).collect();
            self.consume_line(&line);
        }
    }

    fn finish(mut self) -> Option<Value> {
        if !self.buffer.is_empty() {
            let line = std::mem::take(&mut self.buffer);
            self.consume_line(&line);
        }
        self.terminal
    }

    fn consume_line(&mut self, line: &[u8]) {
        let line = String::from_utf8_lossy(line);
        let Some(data) = line.trim().strip_prefix("data:") else {
            return;
        };
        let Ok(event) = serde_json::from_str::<Value>(data.trim()) else {
            return;
        };
        if matches!(
            event.get("type").and_then(Value::as_str),
            Some("response.completed" | "response.incomplete")
        ) {
            self.terminal = event.get("response").cloned();
        }
    }
}

fn append_capture(buffer: &mut Vec<u8>, bytes: &[u8]) {
    const LIMIT: usize = 1_048_576;
    let remaining = LIMIT.saturating_sub(buffer.len());
    buffer.extend_from_slice(&bytes[..bytes.len().min(remaining)]);
}

async fn read_response_body(
    response: UpstreamResponse,
    limit: usize,
    timeout: Duration,
) -> Result<Bytes, GatewayError> {
    tokio::time::timeout(timeout, response.bytes_with_limit(limit))
        .await
        .map_err(|_| {
            GatewayError::UpstreamTransient(format!(
                "response body did not finish within {} seconds",
                timeout.as_secs()
            ))
        })?
}

fn response_with_headers(status: StatusCode, headers: HeaderMap, body: Body) -> Response {
    let mut response = Response::builder().status(status).body(body).unwrap();
    *response.headers_mut() = headers;
    response
}

fn error_response(status: StatusCode, message: &str, kind: &str) -> Response {
    let (headers, body) = error_response_content(message, kind);
    response_with_headers(status, headers, Body::from(body))
}

fn error_response_content(message: &str, kind: &str) -> (HeaderMap, Vec<u8>) {
    let body = serde_json::to_vec(&json!({
        "type": "error",
        "error": { "type": kind, "message": message }
    }))
    .unwrap_or_default();
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    (headers, body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::monitor::MonitorRecord;
    use std::collections::HashMap;

    fn provider(base_url: &str, protocol: WireProtocol) -> ProviderConfig {
        ProviderConfig {
            id: "provider".into(),
            name: "Provider".into(),
            base_url: base_url.into(),
            auth_token: String::new(),
            default_model: String::new(),
            small_fast_model: String::new(),
            map_default_models: true,
            protocol,
            models: vec![],
            enabled: true,
            headers: HashMap::new(),
            timeout_seconds: 60,
        }
    }

    fn stream_test_state() -> Arc<GatewayState> {
        GatewayState::new(
            serde_json::from_value(json!({
                "publicPort": 8788,
                "management": {
                    "port": 0,
                    "bearerToken": "0123456789abcdef0123456789abcdef"
                },
                "activeProviderId": "provider",
                "providers": [{
                    "id": "provider",
                    "name": "Provider",
                    "baseUrl": "https://example.com/v1",
                    "protocol": "anthropic"
                }]
            }))
            .unwrap(),
        )
    }

    fn passthrough_prepared_request() -> PreparedRequest {
        PreparedRequest {
            target: "https://example.com/v1/messages".parse().unwrap(),
            v1_fallback_target: None,
            headers: HeaderMap::new(),
            body: Vec::new(),
            client_wire: Some(Wire::Anthropic),
            provider_wire: Wire::Anthropic,
            client_model: "client-model".into(),
            wanted_stream: true,
            translation: None,
            history_scope: String::new(),
            history_request: None,
            tool_context: protocol::openai_responses::CodexToolContext::default(),
            hosted_web_search: None,
        }
    }

    async fn wait_for_monitor_terminal(state: &GatewayState, id: u64) -> MonitorRecord {
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if let Some(detail) = state.monitor.detail(id).await {
                    if detail.elapsed_ms.is_some() {
                        return detail;
                    }
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("stream monitor record remained pending")
    }

    #[test]
    fn collapses_duplicate_version_prefix() {
        let uri: Uri = "/v1/models?limit=2".parse().unwrap();
        assert_eq!(
            collapse_overlapping_path("https://example.com/v1", &uri),
            "https://example.com/v1/models?limit=2"
        );
    }

    #[test]
    fn alpha_search_targets_match_origin_versioned_custom_and_full_response_bases() {
        let cases = [
            (
                "https://example.com",
                "https://example.com/v1/alpha/search?client_version=1",
            ),
            (
                "https://example.com/v1/",
                "https://example.com/v1/alpha/search?client_version=1",
            ),
            (
                "https://example.com/backend-api/codex",
                "https://example.com/backend-api/codex/alpha/search?client_version=1",
            ),
            (
                "https://example.com/backend-api/codex/responses?api-version=test",
                "https://example.com/backend-api/codex/alpha/search?api-version=test&client_version=1",
            ),
            (
                "https://example.com/backend-api/codex/responses/compact/",
                "https://example.com/backend-api/codex/alpha/search?client_version=1",
            ),
        ];
        let uri: Uri = "/codex/v1/alpha/search?client_version=1".parse().unwrap();
        for (base_url, expected) in cases {
            assert_eq!(
                build_target(
                    &provider(base_url, WireProtocol::OpenaiResponses),
                    &uri,
                    Some(Wire::OpenAiResponses),
                )
                .unwrap()
                .to_string(),
                expected,
                "{base_url}"
            );
            assert!(build_v1_fallback_target(
                &provider(base_url, WireProtocol::OpenaiResponses),
                &uri,
                Some(Wire::OpenAiResponses),
            )
            .unwrap()
            .is_none());
        }
    }

    #[test]
    fn terminal_responses_event_is_recovered_for_history() {
        let event = responses_terminal_event(
            b"event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"status\":\"completed\",\"object\":\"response\",\"output\":[]}}\n\n",
        )
        .unwrap();
        assert_eq!(event["id"], "r1");
    }

    #[test]
    fn builds_v1_fallback_only_for_unversioned_provider_bases() {
        let uri: Uri = "/v1/messages?trace=yes".parse().unwrap();
        assert_eq!(
            build_v1_fallback_target(
                &provider("https://example.com", WireProtocol::OpenaiChat),
                &uri,
                Some(Wire::Anthropic),
            )
            .unwrap()
            .unwrap()
            .to_string(),
            "https://example.com/v1/chat/completions?trace=yes"
        );
        assert!(build_v1_fallback_target(
            &provider("https://example.com/v1", WireProtocol::OpenaiChat),
            &uri,
            Some(Wire::Anthropic),
        )
        .unwrap()
        .is_none());
    }

    #[test]
    fn detects_success_status_failure_envelopes() {
        assert_eq!(
            semantic_failure_message(
                br#"{"status":"failed","error":{"type":"server_error","message":"boom"}}"#
            )
            .as_deref(),
            Some("server_error: boom")
        );
        assert_eq!(
            semantic_failure_message(br#"{"type":"error","error":{"message":"denied"}}"#)
                .as_deref(),
            Some("upstream_error: denied")
        );
        assert!(semantic_failure_message(br#"{"status":"incomplete","error":null}"#).is_none());
    }

    #[test]
    fn detects_hosted_web_search_without_blocking_same_named_functions() {
        for body in [
            json!({"tools":[{"type":"web_search"}]}),
            json!({"tools":[{"type":"web_search_20260318","name":"web_search"}]}),
            json!({"input":[{"type":"web_search_call","id":"search-1"}]}),
            json!({
                "messages":[{
                    "role":"assistant",
                    "content":[{"type":"server_tool_use","name":"web_search"}]
                }]
            }),
            json!({
                "messages":[{
                    "role":"user",
                    "content":[{"type":"web_search_tool_result","tool_use_id":"search-1"}]
                }]
            }),
        ] {
            assert!(request_uses_hosted_web_search(&body), "{body}");
        }
        assert!(!request_uses_hosted_web_search(&json!({
            "tools":[{"type":"function","name":"web_search"}]
        })));
    }

    #[test]
    fn local_auxiliary_routes_do_not_depend_on_an_upstream() {
        let state = GatewayState::new(
            serde_json::from_value(json!({
                "publicPort": 8788,
                "management": {
                    "port": 0,
                    "bearerToken": "0123456789abcdef0123456789abcdef"
                },
                "activeProviderId": "one",
                "providers": [{
                    "id": "one",
                    "name": "One",
                    "baseUrl": "https://example.com/v1",
                    "defaultModel": "upstream-primary"
                }]
            }))
            .unwrap(),
        );
        let models = local_response(
            &state,
            &Method::GET,
            &"/v1/models".parse().unwrap(),
            &HeaderMap::new(),
            None,
        )
        .unwrap();
        let models_body: Value = serde_json::from_slice(&models.2).unwrap();
        assert!(models_body["data"]
            .as_array()
            .is_some_and(|data| !data.is_empty()));

        let count = local_response(
            &state,
            &Method::POST,
            &"/v1/messages/count_tokens".parse().unwrap(),
            &HeaderMap::new(),
            Some(&json!({"messages":[{"role":"user","content":"hello"}]})),
        )
        .unwrap();
        let count_body: Value = serde_json::from_slice(&count.2).unwrap();
        assert!(count_body["input_tokens"]
            .as_i64()
            .is_some_and(|value| value > 0));
        assert_eq!(count.1["x-ccbud-tokens"], "estimated");
    }

    #[test]
    fn responses_stream_priming_waits_through_lifecycle_and_rejects_failure() {
        assert!(inspect_responses_stream_block(
            "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"status\":\"in_progress\"}}\n\n"
        )
        .is_none());
        assert!(inspect_responses_stream_block(
            "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n"
        )
        .unwrap()
        .is_ok());
        assert!(inspect_responses_stream_block(
            "event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"type\":\"server_error\",\"message\":\"boom\"}}}\n\n"
        )
        .unwrap()
        .is_err());
    }

    #[tokio::test]
    async fn dropping_client_stream_body_marks_monitor_record_cancelled() {
        let state = stream_test_state();
        let monitor_id = state
            .monitor
            .begin("POST", "/v1/messages", None, &HeaderMap::new(), b"{}")
            .await;
        let mut headers = HeaderMap::new();
        headers.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("text/event-stream"),
        );
        let response = passthrough_stream_response(
            state.clone(),
            monitor_id,
            Instant::now(),
            &provider("https://example.com/v1", WireProtocol::Anthropic),
            passthrough_prepared_request(),
            headers.clone(),
            UpstreamResponse::streamed(
                StatusCode::OK,
                headers,
                futures::stream::pending::<Result<Bytes, std::io::Error>>(),
            ),
        );

        drop(response);

        let detail = wait_for_monitor_terminal(&state, monitor_id).await;
        assert_eq!(detail.status, None);
        assert_eq!(
            detail.error.as_deref(),
            Some("client disconnected before response stream completed")
        );
    }

    #[tokio::test]
    async fn passthrough_stream_error_is_not_recorded_as_completed_200() {
        let state = stream_test_state();
        let monitor_id = state
            .monitor
            .begin("POST", "/v1/messages", None, &HeaderMap::new(), b"{}")
            .await;
        let mut headers = HeaderMap::new();
        headers.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("text/event-stream"),
        );
        let response = passthrough_stream_response(
            state.clone(),
            monitor_id,
            Instant::now(),
            &provider("https://example.com/v1", WireProtocol::Anthropic),
            passthrough_prepared_request(),
            headers.clone(),
            UpstreamResponse::streamed(
                StatusCode::OK,
                headers,
                futures::stream::iter([
                    Ok(Bytes::from_static(b"event: content\ndata: hello\n\n")),
                    Err(std::io::Error::other("socket reset")),
                ]),
            ),
        );

        assert!(to_bytes(response.into_body(), 1024).await.is_err());

        let detail = wait_for_monitor_terminal(&state, monitor_id).await;
        assert_eq!(detail.status, None);
        assert_eq!(
            detail.error.as_deref(),
            Some("upstream stream error: socket reset")
        );
        assert_eq!(
            detail.upstream_response.unwrap().body,
            "event: content\ndata: hello\n\n"
        );
    }
}
