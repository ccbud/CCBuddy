// The translation pipeline itself: decode(client wire) → IR → encode(provider wire) on the way
// out, and the mirror on the way back. The identity case (client and provider speak the same
// protocol) never enters here — the gateway keeps its verbatim passthrough fast path for it.

use super::signatures::{
    ensure_chat_tool_call_reasoning_content, normalize_openai_request_thought_signatures,
    normalize_openai_response_thought_signatures,
};
use super::{anthropic, openai_chat_client, openai_responses, stream};
use super::Wire;
use llm_connector::core::Protocol;
use llm_connector::protocols::adapters::anthropic::AnthropicProtocol;
use llm_connector::protocols::adapters::openai::OpenAIProtocol;
use llm_connector::types::{ChatRequest, ChatResponse};
use serde_json::{json, Value};

/// Decode an inbound client request (in its wire format) into the unified IR.
pub fn decode_client_request(client: Wire, body: &Value) -> Result<ChatRequest, String> {
    match client {
        Wire::Anthropic => anthropic::decode_request(body),
        Wire::OpenAiChat => openai_chat_client::decode_request(body),
        // Hand-rolled (not the crate's responses_request_to_chat_request, which drops
        // function_call / function_call_output / assistant items and rejects flattened tools —
        // fatal for Codex).
        Wire::OpenAiResponses => openai_responses::decode_request(body),
    }
}

/// Encode the IR into the upstream provider's request BODY. `outgoing_model` is the provider's real
/// model (gateway already resolved it); `stream` requests SSE from the upstream. For the first cut
/// we translate cross-protocol responses buffered, so callers pass stream=false here and synthesize
/// the client SSE from the full response (true incremental transcoding is P2).
pub fn encode_upstream_request(
    provider: Wire,
    ir: &ChatRequest,
    outgoing_model: &str,
    stream: bool,
) -> Result<Value, String> {
    let mut ir = ir.clone();
    ir.model = outgoing_model.to_string();
    ir.stream = Some(stream);
    match provider {
        Wire::OpenAiChat => {
            let mut body = OpenAIProtocol::new("")
                .build_chat_request_body(&ir)
                .map_err(|e| e.to_string())?;
            let lower_model = outgoing_model.to_ascii_lowercase();
            if lower_model.contains("gemini") {
                normalize_openai_request_thought_signatures(&mut body);
            }
            // GLM's OpenAI-compatible coding endpoint uses its native `thinking` switch rather
            // than the OpenAI `reasoning_effort` field emitted by the generic connector.
            if lower_model.contains("glm") || lower_model.contains("zhipu") || lower_model.contains("z-ai") {
                if let Some(object) = body.as_object_mut() {
                    object.remove("reasoning_effort");
                }
                if ir.enable_thinking == Some(true) {
                    body["thinking"] = json!({ "type": "enabled" });
                }
            }
            ensure_chat_tool_call_reasoning_content(&mut body);
            Ok(body)
        }
        Wire::OpenAiResponses => Ok(openai_responses::encode_request(&ir, outgoing_model, stream)),
        // Reverse direction: an OpenAI/Codex client → an Anthropic upstream. The crate encodes the
        // IR into an Anthropic Messages request (tool_calls→tool_use blocks, etc.). Anthropic
        // requires max_tokens; OpenAI-family clients (Codex) usually omit it and the crate's
        // fallback (1024) truncates agent turns — default to a workable ceiling instead.
        Wire::Anthropic => {
            if ir.max_tokens.is_none() {
                ir.max_tokens = Some(8192);
            }
            AnthropicProtocol::new("")
                .build_chat_request_body(&ir)
                .map_err(|e| e.to_string())
        }
    }
}

/// Decode an upstream provider RESPONSE (its wire format, buffered) into the IR.
pub fn decode_upstream_response(provider: Wire, text: &str) -> Result<ChatResponse, String> {
    match provider {
        Wire::OpenAiChat => {
            let normalized = match serde_json::from_str::<Value>(text) {
                Ok(mut body) => {
                    normalize_openai_response_thought_signatures(&mut body);
                    body.to_string()
                }
                Err(_) => text.to_string(),
            };
            OpenAIProtocol::new("").parse_response(&normalized).map_err(|e| e.to_string())
        }
        Wire::OpenAiResponses => openai_responses::decode_response(text),
        Wire::Anthropic => AnthropicProtocol::new("").parse_response(text).map_err(|e| e.to_string()),
    }
}

/// Encode the IR response back to the client's wire format as a buffered JSON body.
pub fn encode_client_response(client: Wire, ir: &ChatResponse, client_model: &str) -> Result<Value, String> {
    match client {
        Wire::Anthropic => Ok(anthropic::encode_response(ir, client_model)),
        Wire::OpenAiChat => Ok(openai_chat_client::encode_response(ir, client_model)),
        // Hand-rolled (not the crate's chat_response_to_responses_response, which drops
        // tool_calls from the output — Codex would never see a function call).
        Wire::OpenAiResponses => Ok(openai_responses::encode_response(ir, client_model)),
    }
}

/// Whether we have an incremental (event-by-event) stream transcoder from `provider` to `client`.
/// When false, cross-protocol streaming falls back to buffer-upstream + synthesize-client-SSE.
pub fn can_transcode_stream(provider: Wire, client: Wire) -> bool {
    stream::Transcoder::supports(provider, client)
}

/// Encode the IR response to the client's wire format as a full SSE stream body (used when the
/// client asked to stream but we translated the upstream buffered — synthesize the event sequence).
pub fn encode_client_response_sse(client: Wire, ir: &ChatResponse, client_model: &str) -> Result<String, String> {
    match client {
        Wire::Anthropic => Ok(anthropic::encode_response_sse(ir, client_model)),
        Wire::OpenAiChat => Ok(openai_chat_client::encode_response_sse(ir, client_model)),
        Wire::OpenAiResponses => Ok(openai_responses::encode_response_sse(ir, client_model)),
    }
}
