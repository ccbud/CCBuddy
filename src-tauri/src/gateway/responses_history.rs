use bytes::Bytes;
use serde_json::{json, Value};

use crate::protocol::codex_history::{HistoryResolution, ResponseOrigin};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ResponsesForwardMode {
    Original,
    Materialized,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct ResponsesHistoryDecision {
    pub(super) forward: ResponsesForwardMode,
    pub(super) descendant_materializable: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ResponsesHistoryError {
    Unavailable,
}

#[derive(Clone)]
pub(super) struct NativeResponsesHistoryContext {
    pub(super) scope: String,
    pub(super) request: Value,
    pub(super) provider_id: String,
    pub(super) materializable: bool,
}

pub(super) fn decide_responses_history(
    provider_wire: crate::protocol::Wire,
    provider_id: &str,
    resolution: &HistoryResolution,
) -> Result<ResponsesHistoryDecision, ResponsesHistoryError> {
    if !resolution.had_previous_response_id {
        return Ok(ResponsesHistoryDecision {
            forward: if resolution.changed > 0 {
                ResponsesForwardMode::Materialized
            } else {
                ResponsesForwardMode::Original
            },
            descendant_materializable: true,
        });
    }

    if provider_wire != crate::protocol::Wire::OpenAiResponses {
        return (resolution.previous_found && resolution.previous_materialized)
            .then_some(ResponsesHistoryDecision {
                forward: ResponsesForwardMode::Materialized,
                descendant_materializable: true,
            })
            .ok_or(ResponsesHistoryError::Unavailable);
    }

    if !resolution.previous_found {
        // Restart compatibility: the selected native provider may still own this id even though
        // the gateway cache does not. Keep the id intact, but do not make descendants portable.
        return Ok(ResponsesHistoryDecision {
            forward: ResponsesForwardMode::Original,
            descendant_materializable: false,
        });
    }

    let same_native_owner = matches!(
        resolution.previous_origin.as_ref(),
        Some(ResponseOrigin::Native(owner)) if owner == provider_id
    );
    if same_native_owner {
        return Ok(ResponsesHistoryDecision {
            forward: ResponsesForwardMode::Original,
            descendant_materializable: resolution.previous_materialized,
        });
    }

    resolution
        .previous_materialized
        .then_some(ResponsesHistoryDecision {
            forward: ResponsesForwardMode::Materialized,
            descendant_materializable: true,
        })
        .ok_or(ResponsesHistoryError::Unavailable)
}

pub(super) fn decide_responses_compact_history(
    provider_id: &str,
    resolution: &HistoryResolution,
) -> Result<ResponsesForwardMode, ResponsesHistoryError> {
    decide_responses_history(
        crate::protocol::Wire::OpenAiResponses,
        provider_id,
        resolution,
    )
    .map(|decision| decision.forward)
}

pub(super) fn request_body_with_model(request: &Value, outgoing_model: Option<&str>) -> Option<Bytes> {
    let mut request = request.clone();
    if let (Some(object), Some(model)) = (request.as_object_mut(), outgoing_model) {
        object.insert("model".to_string(), Value::String(model.to_string()));
    }
    serde_json::to_vec(&request).ok().map(Bytes::from)
}

pub(super) fn apply_responses_chat_request_controls(body: &mut Value, request: &Value) {
    if let Some(parallel_tool_calls) = request
        .get("parallel_tool_calls")
        .and_then(Value::as_bool)
    {
        body["parallel_tool_calls"] = json!(parallel_tool_calls);
    }
}
