use axum::{
    http::{Method, StatusCode},
    response::Response,
};
use bytes::Bytes;
use serde_json::Value;
use std::sync::Arc;

use super::responses_history::{
    decide_responses_compact_history, decide_responses_history, request_body_with_model,
    NativeResponsesHistoryContext, ResponsesForwardMode, ResponsesHistoryError,
};
use super::routing::Routing;
use super::state::GatewayState;
use super::targets::error_response;

#[allow(clippy::too_many_arguments)]
pub(super) async fn prepare_responses_history(
    st: &Arc<GatewayState>,
    parsed: &Option<Value>,
    method: &Method,
    client_wire: crate::protocol::Wire,
    provider_wire: crate::protocol::Wire,
    routing: &Routing,
    provider_name: &str,
    codex_history_scope: &str,
    allow_codex_call_fallback: bool,
    is_responses_compact: bool,
    out_body: &mut Bytes,
    history_localized: &mut bool,
    prepared_responses_request: &mut Option<Value>,
    native_responses_history: &mut Option<NativeResponsesHistoryContext>,
) -> Option<Response> {
    if is_responses_compact {
        if let Some(request) = parsed.as_ref() {
            let previous_response_id = request
                .get("previous_response_id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToString::to_string);
            let mut materialized_request = request.clone();
            let resolution = st
                .codex_history
                .materialize_request_scoped(
                    &codex_history_scope,
                    allow_codex_call_fallback,
                    &mut materialized_request,
                )
                .await;
            let forward = match decide_responses_compact_history(
                &routing.provider_id,
                &resolution,
            ) {
                Ok(forward) => forward,
                Err(ResponsesHistoryError::Unavailable) => {
                    return Some(error_response(
                        StatusCode::BAD_REQUEST,
                        &format!(
                            "CC Buddy cannot compact previous_response_id '{}' with provider '{}': its complete context cannot be materialized; retry with the owning Responses provider",
                            previous_response_id.as_deref().unwrap_or("<missing>"),
                            provider_name
                        ),
                        "invalid_request_error",
                    ));
                }
            };
            if forward == ResponsesForwardMode::Materialized {
                *history_localized = true;
                let Some(body) = request_body_with_model(
                    &materialized_request,
                    routing.outgoing_model.as_deref(),
                ) else {
                    return Some(error_response(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "CC Buddy failed to serialize locally materialized compact history",
                        "api_error",
                    ));
                };
                *out_body = body;
            }
        }
    } else if client_wire == crate::protocol::Wire::OpenAiResponses && *method == Method::POST {
        if let Some(request) = parsed.as_ref() {
            let previous_response_id = request
                .get("previous_response_id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToString::to_string);
            let mut materialized_request = request.clone();
            let resolution = st
                .codex_history
                .materialize_request_scoped(
                    &codex_history_scope,
                    allow_codex_call_fallback,
                    &mut materialized_request,
                )
                .await;
            let decision = match decide_responses_history(
                provider_wire,
                &routing.provider_id,
                &resolution,
            ) {
                Ok(decision) => decision,
                Err(ResponsesHistoryError::Unavailable) => {
                    let detail = if resolution.previous_found {
                        "is known locally but its complete context cannot be materialized"
                    } else {
                        "is not available in local history"
                    };
                    return Some(error_response(
                        StatusCode::BAD_REQUEST,
                        &format!(
                            "CC Buddy cannot continue previous_response_id '{}' through provider '{}': it {}; retry with the owning Responses provider or start a new conversation",
                            previous_response_id.as_deref().unwrap_or("<missing>"),
                            provider_name,
                            detail
                        ),
                        "invalid_request_error",
                    ));
                }
            };
            if decision.forward == ResponsesForwardMode::Materialized {
                *history_localized = true;
                if provider_wire == crate::protocol::Wire::OpenAiResponses {
                    let Some(body) = request_body_with_model(
                        &materialized_request,
                        routing.outgoing_model.as_deref(),
                    ) else {
                        return Some(error_response(
                            StatusCode::INTERNAL_SERVER_ERROR,
                            "CC Buddy failed to serialize locally materialized Responses history",
                            "api_error",
                        ));
                    };
                    *out_body = body;
                }
            }
            if provider_wire == crate::protocol::Wire::OpenAiResponses {
                *native_responses_history = Some(NativeResponsesHistoryContext {
                    scope: codex_history_scope.to_string(),
                    request: materialized_request.clone(),
                    provider_id: routing.provider_id.clone(),
                    materializable: decision.descendant_materializable,
                });
            }
            *prepared_responses_request = Some(materialized_request);
        }
    }
    None
}
