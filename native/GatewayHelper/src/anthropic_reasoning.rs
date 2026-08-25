//! Lossless Anthropic signed-thinking replay for the Codex Responses bridge.
//!
//! Anthropic requires the exact `thinking`/`redacted_thinking` block returned with a tool call to
//! be sent back on the following tool-result turn. Responses has no native Anthropic block, so the
//! current cc-switch bridge carries it in `reasoning.encrypted_content` under a versioned prefix.
//! Only envelopes minted by this bridge and containing a real signature/redacted payload are ever
//! replayed; foreign or malformed ciphertext remains opaque and cannot become an Anthropic block.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashSet};

pub const ANTHROPIC_THINKING_ENCRYPTED_PREFIX: &str = "ccswitch-anthropic-thinking-v1:";

/// Preserve a provider-authenticated Anthropic thinking block in a Responses reasoning item.
pub fn encode_anthropic_thinking_block(block: &Value) -> Option<String> {
    match block.get("type").and_then(Value::as_str) {
        Some("thinking")
            if block
                .get("signature")
                .and_then(Value::as_str)
                .is_some_and(|value| !value.is_empty()) => {}
        Some("redacted_thinking")
            if block
                .get("data")
                .and_then(Value::as_str)
                .is_some_and(|value| !value.is_empty()) => {}
        _ => return None,
    }
    let bytes = serde_json::to_vec(block).ok()?;
    Some(format!(
        "{ANTHROPIC_THINKING_ENCRYPTED_PREFIX}{}",
        URL_SAFE_NO_PAD.encode(bytes)
    ))
}

/// Decode only this bridge's validated envelope.
pub fn decode_anthropic_thinking_block(encrypted_content: &str) -> Option<Value> {
    let encoded = encrypted_content.strip_prefix(ANTHROPIC_THINKING_ENCRYPTED_PREFIX)?;
    let bytes = URL_SAFE_NO_PAD.decode(encoded).ok()?;
    let block: Value = serde_json::from_slice(&bytes).ok()?;
    // Reuse the encoder validation: an old/malformed envelope must never turn into an unsigned
    // thinking block on an authenticated Anthropic tool continuation.
    encode_anthropic_thinking_block(&block).map(|_| block)
}

fn responses_reasoning_item_from_anthropic_block(item_id: &str, block: &Value) -> Option<Value> {
    let encrypted_content = encode_anthropic_thinking_block(block)?;
    let summary = block
        .get("thinking")
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
        .map(|text| vec![json!({"type":"summary_text", "text":text})])
        .unwrap_or_default();
    Some(json!({
        "id": item_id,
        "type": "reasoning",
        "summary": summary,
        "encrypted_content": encrypted_content
    }))
}

#[derive(Default)]
struct ReplayTurn {
    blocks: Vec<Value>,
    call_ids: HashSet<String>,
    has_assistant_payload: bool,
}

fn response_item_type(item: &Value) -> &str {
    item.get("type").and_then(Value::as_str).unwrap_or_else(|| {
        if item.get("role").is_some() {
            "message"
        } else {
            ""
        }
    })
}

/// Recover signed blocks from the original flat Responses history and group them by assistant
/// turn. This mirrors cc-switch's `convert_input_to_messages`: reasoning immediately before or
/// after assistant prose/tool calls belongs to that same assistant turn; a user/tool-result item
/// starts a new boundary.
fn replay_turns(request: &Value) -> Vec<ReplayTurn> {
    let Some(items) = request.get("input").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut turns: Vec<ReplayTurn> = Vec::new();
    let mut current: Option<usize> = None;

    let ensure_turn = |turns: &mut Vec<ReplayTurn>, current: &mut Option<usize>| -> usize {
        if let Some(index) = *current {
            index
        } else {
            let index = turns.len();
            turns.push(ReplayTurn::default());
            *current = Some(index);
            index
        }
    };

    for item in items {
        match response_item_type(item) {
            "reasoning" => {
                let Some(block) = item
                    .get("encrypted_content")
                    .and_then(Value::as_str)
                    .and_then(decode_anthropic_thinking_block)
                else {
                    continue;
                };
                let index = ensure_turn(&mut turns, &mut current);
                turns[index].blocks.push(block);
            }
            "function_call" | "custom_tool_call" | "tool_search_call" => {
                let index = ensure_turn(&mut turns, &mut current);
                turns[index].has_assistant_payload = true;
                if let Some(call_id) = item
                    .get("call_id")
                    .or_else(|| item.get("id"))
                    .and_then(Value::as_str)
                    .filter(|value| !value.is_empty())
                {
                    turns[index].call_ids.insert(call_id.to_string());
                }
            }
            "message" if item.get("role").and_then(Value::as_str) == Some("assistant") => {
                let index = ensure_turn(&mut turns, &mut current);
                turns[index].has_assistant_payload = true;
            }
            "function_call_output"
            | "custom_tool_call_output"
            | "tool_search_output"
            | "input_text"
            | "input_image"
            | "input_file" => current = None,
            "message" => current = None,
            _ => {}
        }
    }

    turns
        .into_iter()
        .filter(|turn| !turn.blocks.is_empty())
        .collect()
}

fn message_tool_use_ids(message: &Value) -> HashSet<&str> {
    message
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("tool_use"))
        .filter_map(|block| block.get("id").and_then(Value::as_str))
        .collect()
}

fn insert_replay_blocks(request: &Value, anthropic: &mut Value) {
    let Some(messages) = anthropic.get_mut("messages").and_then(Value::as_array_mut) else {
        return;
    };

    // The generic IR carries a visible reasoning summary as an unsigned Anthropic thinking block.
    // It is useful for Chat-family upstreams but illegal evidence for an Anthropic tool replay.
    for message in messages.iter_mut() {
        if message.get("role").and_then(Value::as_str) != Some("assistant") {
            continue;
        }
        if let Some(content) = message.get_mut("content").and_then(Value::as_array_mut) {
            content.retain(|block| {
                !matches!(
                    block.get("type").and_then(Value::as_str),
                    Some("thinking" | "redacted_thinking")
                )
            });
        }
    }

    let mut used_messages = HashSet::new();
    let mut sequential_cursor = 0usize;
    for turn in replay_turns(request) {
        let by_call_id = (!turn.call_ids.is_empty()).then(|| {
            messages.iter().enumerate().find_map(|(index, message)| {
                if used_messages.contains(&index)
                    || message.get("role").and_then(Value::as_str) != Some("assistant")
                {
                    return None;
                }
                let ids = message_tool_use_ids(message);
                turn.call_ids
                    .iter()
                    .all(|call_id| ids.contains(call_id.as_str()))
                    .then_some(index)
            })
        });
        let index = by_call_id.flatten().or_else(|| {
            if !turn.has_assistant_payload {
                return None;
            }
            let found = messages
                .iter()
                .enumerate()
                .skip(sequential_cursor)
                .find(|(index, message)| {
                    !used_messages.contains(index)
                        && message.get("role").and_then(Value::as_str) == Some("assistant")
                })
                .map(|(index, _)| index);
            if let Some(index) = found {
                sequential_cursor = index.saturating_add(1);
            }
            found
        });
        let Some(index) = index else {
            // Fail closed: without an unambiguous assistant turn, never replay the block.
            continue;
        };
        used_messages.insert(index);
        let Some(content) = messages[index]
            .get_mut("content")
            .and_then(Value::as_array_mut)
        else {
            continue;
        };
        for block in turn.blocks.into_iter().rev() {
            content.insert(0, block);
        }
    }
}

fn effort_to_thinking_budget(effort: &str) -> Option<u64> {
    match effort.trim().to_ascii_lowercase().as_str() {
        "minimal" | "low" => Some(2048),
        "medium" => Some(8192),
        "high" => Some(16384),
        "xhigh" | "max" | "ultra" => Some(24576),
        _ => None,
    }
}

fn codex_effort_to_anthropic(effort: &str) -> Option<&'static str> {
    match effort.trim().to_ascii_lowercase().as_str() {
        "minimal" | "low" => Some("low"),
        "medium" => Some("medium"),
        "high" => Some("high"),
        "xhigh" | "max" | "ultra" => Some("max"),
        _ => None,
    }
}

fn normalized_model(model: &str) -> String {
    model.trim().to_ascii_lowercase().replace(['.', '_'], "-")
}

fn uses_adaptive_thinking(model: &str) -> bool {
    let model = normalized_model(model);
    [
        "fable-5",
        "mythos-5",
        "mythos-preview",
        "sonnet-5",
        "opus-4-8",
        "opus-4-7",
        "opus-4-6",
        "sonnet-4-6",
    ]
    .iter()
    .any(|needle| model.contains(needle))
}

fn adaptive_thinking_is_default(model: &str) -> bool {
    let model = normalized_model(model);
    ["fable-5", "mythos-5", "mythos-preview", "sonnet-5"]
        .iter()
        .any(|needle| model.contains(needle))
}

fn thinking_cannot_be_disabled(model: &str) -> bool {
    let model = normalized_model(model);
    ["fable-5", "mythos-5"]
        .iter()
        .any(|needle| model.contains(needle))
}

fn reasoning_explicitly_disabled(effort: Option<&str>) -> bool {
    matches!(
        effort
            .map(str::trim)
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("none" | "off" | "disabled")
    )
}

/// A fresh prompt can start thinking. A tool-result continuation can keep it enabled only if the
/// immediately preceding assistant tool turn contains a validated signed/redacted block and every
/// result answers a tool in that exact turn. Looking farther back would incorrectly reuse an old
/// signature for a newer unsigned tool call.
fn trailing_turn_supports_thinking(messages: &[Value]) -> bool {
    let Some(last) = messages.last() else {
        return false;
    };
    if last.get("role").and_then(Value::as_str) != Some("user") {
        return false;
    }
    let mut result_ids = Vec::new();
    if let Some(blocks) = last.get("content").and_then(Value::as_array) {
        for block in blocks {
            if block.get("type").and_then(Value::as_str) != Some("tool_result") {
                continue;
            }
            let Some(id) = block
                .get("tool_use_id")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
            else {
                return false;
            };
            result_ids.push(id);
        }
    }
    if result_ids.is_empty() {
        return true;
    }

    let Some(assistant) = messages.get(messages.len().saturating_sub(2)) else {
        return false;
    };
    if assistant.get("role").and_then(Value::as_str) != Some("assistant") {
        return false;
    }
    let Some(blocks) = assistant.get("content").and_then(Value::as_array) else {
        return false;
    };
    if !blocks.iter().any(|block| {
        matches!(
            block.get("type").and_then(Value::as_str),
            Some("thinking" | "redacted_thinking")
        )
    }) {
        return false;
    }
    let tool_ids = blocks
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("tool_use"))
        .filter_map(|block| block.get("id").and_then(Value::as_str))
        .collect::<HashSet<_>>();
    result_ids.iter().all(|id| tool_ids.contains(id))
}

fn forced_tool_choice(anthropic: &Value) -> bool {
    matches!(
        anthropic
            .pointer("/tool_choice/type")
            .and_then(Value::as_str),
        Some("any" | "tool")
    )
}

fn restore_sampling(request: &Value, anthropic: &mut Value) {
    for key in ["temperature", "top_p"] {
        if let Some(value) = request.get(key) {
            anthropic[key] = value.clone();
        }
    }
}

fn remove_thinking_fields(anthropic: &mut Value) {
    if let Some(object) = anthropic.as_object_mut() {
        object.remove("thinking");
        object.remove("output_config");
    }
}

fn apply_thinking_policy(request: &Value, anthropic: &mut Value) -> Result<(), String> {
    let effort = request.pointer("/reasoning/effort").and_then(Value::as_str);
    let explicitly_disabled = reasoning_explicitly_disabled(effort);
    let model = anthropic.get("model").and_then(Value::as_str).unwrap_or("");
    let adaptive_model = uses_adaptive_thinking(model);
    let adaptive_by_default = adaptive_thinking_is_default(model);
    let cannot_disable = thinking_cannot_be_disabled(model);
    let adaptive_should_think = adaptive_model
        && (adaptive_by_default || effort.and_then(codex_effort_to_anthropic).is_some());
    let history_is_valid = anthropic
        .get("messages")
        .and_then(Value::as_array)
        .is_some_and(|messages| trailing_turn_supports_thinking(messages));

    let mut thinking_enabled = false;
    if !history_is_valid {
        if cannot_disable {
            return Err(
                "Anthropic model requires thinking, but the tool history has no signed thinking block to replay"
                    .to_string(),
            );
        }
        remove_thinking_fields(anthropic);
        if adaptive_should_think {
            anthropic["thinking"] = json!({"type":"disabled"});
        }
    } else if adaptive_should_think && (!explicitly_disabled || cannot_disable) {
        thinking_enabled = true;
        anthropic["thinking"] = json!({"type":"adaptive"});
        if let Some(effort) = effort.and_then(codex_effort_to_anthropic) {
            anthropic["output_config"] = json!({"effort":effort});
        } else if explicitly_disabled && cannot_disable {
            anthropic["output_config"] = json!({"effort":"low"});
        } else if let Some(object) = anthropic.as_object_mut() {
            object.remove("output_config");
        }
    } else if explicitly_disabled {
        anthropic["thinking"] = json!({"type":"disabled"});
        if let Some(object) = anthropic.as_object_mut() {
            object.remove("output_config");
        }
    } else if let Some(mut budget) = effort.and_then(effort_to_thinking_budget) {
        let max_tokens = anthropic
            .get("max_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(8192);
        // Keep visible-answer headroom and Anthropic's minimum thinking budget, matching
        // cc-switch. Never inflate the caller's output ceiling to accommodate thinking.
        budget = budget.min(max_tokens / 2);
        if budget >= 1024 {
            thinking_enabled = true;
            anthropic["thinking"] = json!({"type":"enabled", "budget_tokens":budget});
        } else {
            remove_thinking_fields(anthropic);
        }
    } else {
        remove_thinking_fields(anthropic);
    }

    if thinking_enabled && forced_tool_choice(anthropic) {
        if cannot_disable {
            return Err(
                "Anthropic model requires adaptive thinking and cannot honor a forced tool_choice"
                    .to_string(),
            );
        }
        thinking_enabled = false;
        anthropic["thinking"] = json!({"type":"disabled"});
        if let Some(object) = anthropic.as_object_mut() {
            object.remove("output_config");
        }
    }
    if thinking_enabled {
        if let Some(object) = anthropic.as_object_mut() {
            object.remove("temperature");
            object.remove("top_p");
        }
    } else {
        restore_sampling(request, anthropic);
    }
    Ok(())
}

/// Patch the generic Responses → Anthropic request with cc-switch's signed-replay contract.
pub fn patch_anthropic_request(request: &Value, anthropic: &mut Value) -> Result<(), String> {
    if !anthropic.is_object() {
        return Err("Anthropic request must be a JSON object".to_string());
    }
    // llm-connector may add the derived thinking budget to max_tokens. cc-switch treats
    // Responses max_output_tokens as the actual Anthropic output ceiling and clamps thinking
    // inside it, which avoids exceeding a model's advertised output limit.
    anthropic["max_tokens"] = json!(request
        .get("max_output_tokens")
        .and_then(Value::as_u64)
        .filter(|value| *value > 0)
        .unwrap_or(8192));
    insert_replay_blocks(request, anthropic);
    apply_thinking_policy(request, anthropic)
}

fn responses_usage_from_anthropic(usage: Option<&Value>) -> Value {
    let Some(usage) = usage.filter(|value| value.is_object()) else {
        return json!({
            "input_tokens":0, "output_tokens":0, "total_tokens":0,
            "output_tokens_details":{"reasoning_tokens":0}
        });
    };
    let fresh = usage
        .get("input_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let output = usage
        .get("output_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let cache_read = usage
        .get("cache_read_input_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let cache_write = usage
        .get("cache_creation_input_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let reasoning = usage
        .pointer("/output_tokens_details/thinking_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let input = fresh.saturating_add(cache_read).saturating_add(cache_write);
    let mut result = json!({
        "input_tokens":input,
        "output_tokens":output,
        "total_tokens":input.saturating_add(output),
        "output_tokens_details":{"reasoning_tokens":reasoning}
    });
    if cache_read > 0 || cache_write > 0 {
        result["input_tokens_details"] =
            json!({"cached_tokens":cache_read, "cache_write_tokens":cache_write});
    }
    if cache_write > 0 {
        result["cache_creation_input_tokens"] = json!(cache_write);
    }
    result
}

fn apply_stop_reason(source: &Value, response: &mut Value) {
    let (status, incomplete_reason) = match source.get("stop_reason").and_then(Value::as_str) {
        Some("max_tokens" | "model_context_window_exceeded") => {
            ("incomplete", Some("max_output_tokens"))
        }
        Some("refusal") => ("incomplete", Some("content_filter")),
        _ => ("completed", None),
    };
    response["status"] = json!(status);
    if let Some(reason) = incomplete_reason {
        response["incomplete_details"] = json!({"reason":reason});
    } else if let Some(object) = response.as_object_mut() {
        object.remove("incomplete_details");
    }
}

/// Replace lossy generic reasoning output with the exact signed Anthropic blocks. Unsigned
/// thinking is intentionally omitted, matching cc-switch's fail-closed behavior.
pub fn patch_responses_response(source: &Value, response: &mut Value) -> Result<(), String> {
    let response_id = response
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("resp_ccbud")
        .to_string();
    let output = response
        .get_mut("output")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| "Responses output must be an array".to_string())?;
    output.retain(|item| item.get("type").and_then(Value::as_str) != Some("reasoning"));
    for item in output.iter_mut().filter(|item| {
        matches!(
            item.get("type").and_then(Value::as_str),
            Some("function_call" | "custom_tool_call" | "tool_search_call")
        )
    }) {
        if let Some(object) = item.as_object_mut() {
            // The generic IR mirrors reasoning onto tool items for Chat-family providers. The
            // native Anthropic bridge already carries the exact turn as a sibling signed item;
            // duplicating its visible summary here diverges from cc-switch and can double replay.
            object.remove("reasoning_content");
            object.remove("reasoning");
        }
    }
    let mut reasoning = Vec::new();
    if let Some(blocks) = source.get("content").and_then(Value::as_array) {
        for block in blocks {
            if let Some(item) = responses_reasoning_item_from_anthropic_block(
                &format!("rs_{response_id}_{}", reasoning.len()),
                block,
            ) {
                reasoning.push(item);
            }
        }
    }
    // Anthropic extended-thinking blocks precede visible output/tool calls. Keeping that ordering
    // is load-bearing: Codex replays the reasoning item immediately before its function call.
    output.splice(0..0, reasoning);
    response["usage"] = responses_usage_from_anthropic(source.get("usage"));
    apply_stop_reason(source, response);
    Ok(())
}

fn sse_event(value: &Value) -> String {
    let event = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("message");
    format!(
        "event: {event}\ndata: {}\n\n",
        serde_json::to_string(value).unwrap_or_default()
    )
}

/// Synthesize a Codex-compatible Responses SSE lifecycle from the already-patched terminal JSON.
/// Buffering this one cross-wire direction avoids losing an Anthropic `signature_delta` in the
/// generic stream IR while preserving every output item in `response.output_item.done`.
pub fn responses_json_to_sse(response: &Value) -> Result<String, String> {
    let response_id = response
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("resp_ccbud");
    let model = response.get("model").cloned().unwrap_or(Value::Null);
    let items = response
        .get("output")
        .and_then(Value::as_array)
        .ok_or_else(|| "Responses output must be an array".to_string())?;
    let mut out = sse_event(&json!({
        "type":"response.created",
        "response":{"id":response_id,"object":"response","status":"in_progress","model":model}
    }));

    for (output_index, item) in items.iter().enumerate() {
        let item_id = item.get("id").and_then(Value::as_str).unwrap_or("item");
        match item.get("type").and_then(Value::as_str).unwrap_or("") {
            "message" => {
                let content = item
                    .get("content")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                let mut added = item.clone();
                added["status"] = json!("in_progress");
                added["content"] = json!([]);
                out.push_str(&sse_event(&json!({
                    "type":"response.output_item.added","output_index":output_index,"item":added
                })));
                for (content_index, part) in content.iter().enumerate() {
                    if part.get("type").and_then(Value::as_str) != Some("output_text") {
                        continue;
                    }
                    let text = part.get("text").and_then(Value::as_str).unwrap_or("");
                    out.push_str(&sse_event(&json!({
                        "type":"response.content_part.added","item_id":item_id,
                        "output_index":output_index,"content_index":content_index,
                        "part":{"type":"output_text","annotations":[],"text":""}
                    })));
                    if !text.is_empty() {
                        out.push_str(&sse_event(&json!({
                            "type":"response.output_text.delta","item_id":item_id,
                            "output_index":output_index,"content_index":content_index,"delta":text
                        })));
                    }
                    out.push_str(&sse_event(&json!({
                        "type":"response.output_text.done","item_id":item_id,
                        "output_index":output_index,"content_index":content_index,"text":text
                    })));
                    out.push_str(&sse_event(&json!({
                        "type":"response.content_part.done","item_id":item_id,
                        "output_index":output_index,"content_index":content_index,"part":part
                    })));
                }
                out.push_str(&sse_event(&json!({
                    "type":"response.output_item.done","output_index":output_index,"item":item
                })));
            }
            "function_call" => {
                let arguments = item
                    .get("arguments")
                    .and_then(Value::as_str)
                    .unwrap_or("{}");
                let mut added = item.clone();
                added["status"] = json!("in_progress");
                added["arguments"] = json!("");
                out.push_str(&sse_event(&json!({
                    "type":"response.output_item.added","output_index":output_index,"item":added
                })));
                out.push_str(&sse_event(&json!({
                    "type":"response.function_call_arguments.delta","item_id":item_id,
                    "output_index":output_index,"delta":arguments
                })));
                out.push_str(&sse_event(&json!({
                    "type":"response.function_call_arguments.done","item_id":item_id,
                    "output_index":output_index,"arguments":arguments
                })));
                out.push_str(&sse_event(&json!({
                    "type":"response.output_item.done","output_index":output_index,"item":item
                })));
            }
            "custom_tool_call" => {
                let input = item.get("input").and_then(Value::as_str).unwrap_or("");
                let mut added = item.clone();
                added["status"] = json!("in_progress");
                added["input"] = json!("");
                out.push_str(&sse_event(&json!({
                    "type":"response.output_item.added","output_index":output_index,"item":added
                })));
                if !input.is_empty() {
                    out.push_str(&sse_event(&json!({
                        "type":"response.custom_tool_call_input.delta","item_id":item_id,
                        "call_id":item.get("call_id").cloned().unwrap_or(Value::Null),
                        "output_index":output_index,"delta":input
                    })));
                }
                out.push_str(&sse_event(&json!({
                    "type":"response.custom_tool_call_input.done","item_id":item_id,
                    "call_id":item.get("call_id").cloned().unwrap_or(Value::Null),
                    "output_index":output_index,"input":input
                })));
                out.push_str(&sse_event(&json!({
                    "type":"response.output_item.done","output_index":output_index,"item":item
                })));
            }
            "reasoning" => {
                let summary = item
                    .get("summary")
                    .and_then(Value::as_array)
                    .and_then(|items| items.first())
                    .and_then(|part| part.get("text"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                out.push_str(&sse_event(&json!({
                    "type":"response.output_item.added","output_index":output_index,
                    "item":{"type":"reasoning","id":item_id,"summary":[]}
                })));
                if !summary.is_empty() {
                    out.push_str(&sse_event(&json!({
                        "type":"response.reasoning_summary_text.delta","item_id":item_id,
                        "output_index":output_index,"summary_index":0,"delta":summary
                    })));
                }
                out.push_str(&sse_event(&json!({
                    "type":"response.output_item.done","output_index":output_index,"item":item
                })));
            }
            _ => out.push_str(&sse_event(&json!({
                "type":"response.output_item.done","output_index":output_index,"item":item
            }))),
        }
    }

    let terminal = if response.get("status").and_then(Value::as_str) == Some("incomplete") {
        "response.incomplete"
    } else {
        "response.completed"
    };
    out.push_str(&sse_event(&json!({"type":terminal,"response":response})));
    Ok(out)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StreamBlockKind {
    Text,
    Tool,
    Thinking,
}

#[derive(Debug)]
struct StreamBlock {
    kind: StreamBlockKind,
    output_index: u32,
    item_id: String,
    call_id: String,
    name: String,
    accum: String,
    start_input: String,
    source_block: Value,
    has_visible_summary: bool,
    done: bool,
}

/// Incremental Anthropic Messages SSE → Responses SSE bridge derived from cc-switch's
/// `streaming_codex_anthropic`. It owns the source thinking block until `signature_delta` arrives,
/// then emits the authenticated envelope in `response.output_item.done` and the terminal response.
pub struct SignedAnthropicToResponsesStream {
    client_model: String,
    tool_context: crate::protocol::openai_responses::CodexToolContext,
    response_started: bool,
    completed: bool,
    response_id: String,
    next_output_index: u32,
    blocks: BTreeMap<u64, StreamBlock>,
    output_items: Vec<(u32, Value)>,
    anthropic_usage: Map<String, Value>,
    stop_reason: Option<String>,
    stream_truncated: bool,
}

impl SignedAnthropicToResponsesStream {
    pub fn new(
        client_model: &str,
        tool_context: crate::protocol::openai_responses::CodexToolContext,
    ) -> Self {
        Self {
            client_model: client_model.to_string(),
            tool_context,
            response_started: false,
            completed: false,
            response_id: format!("resp_ccbud_{}", uuid::Uuid::new_v4().simple()),
            next_output_index: 0,
            blocks: BTreeMap::new(),
            output_items: Vec::new(),
            anthropic_usage: Map::new(),
            stop_reason: None,
            stream_truncated: false,
        }
    }

    fn next_output_index(&mut self) -> u32 {
        let index = self.next_output_index;
        self.next_output_index = self.next_output_index.saturating_add(1);
        index
    }

    fn merge_usage(&mut self, usage: &Value) {
        if let Some(usage) = usage.as_object() {
            for (key, value) in usage {
                if !value.is_null() {
                    self.anthropic_usage.insert(key.clone(), value.clone());
                }
            }
        }
    }

    fn usage(&self) -> Value {
        responses_usage_from_anthropic(Some(&Value::Object(self.anthropic_usage.clone())))
    }

    fn base_response(&self, status: &str, output: Vec<Value>) -> Value {
        json!({
            "id":self.response_id,
            "object":"response",
            "created_at":0,
            "status":status,
            "model":self.client_model,
            "output":output,
            "usage":self.usage()
        })
    }

    fn ensure_started(&mut self) -> String {
        if self.response_started {
            return String::new();
        }
        self.response_started = true;
        let response = self.base_response("in_progress", Vec::new());
        let mut out = sse_event(&json!({"type":"response.created","response":response}));
        out.push_str(&sse_event(
            &json!({"type":"response.in_progress","response":response}),
        ));
        out
    }

    fn handle_message_start(&mut self, event: &Value) -> String {
        if let Some(message) = event.get("message") {
            if !self.response_started {
                if let Some(id) = message
                    .get("id")
                    .and_then(Value::as_str)
                    .filter(|value| !value.is_empty())
                {
                    self.response_id = if id.starts_with("resp_") {
                        id.to_string()
                    } else {
                        format!("resp_{id}")
                    };
                }
            }
            if let Some(usage) = message.get("usage") {
                self.merge_usage(usage);
            }
        }
        self.ensure_started()
    }

    fn handle_block_start(&mut self, event: &Value) -> String {
        let mut out = self.ensure_started();
        let Some(source_index) = event.get("index").and_then(Value::as_u64) else {
            return out;
        };
        let block = event.get("content_block").unwrap_or(&Value::Null);
        let block_type = block.get("type").and_then(Value::as_str).unwrap_or("");
        match block_type {
            "text" => {
                let output_index = self.next_output_index();
                let item_id = format!(
                    "msg_{}_{}",
                    self.response_id.trim_start_matches("resp_"),
                    output_index
                );
                out.push_str(&sse_event(&json!({
                    "type":"response.output_item.added","output_index":output_index,
                    "item":{"id":item_id,"type":"message","status":"in_progress",
                            "role":"assistant","content":[]}
                })));
                out.push_str(&sse_event(&json!({
                    "type":"response.content_part.added","item_id":item_id,
                    "output_index":output_index,"content_index":0,
                    "part":{"type":"output_text","text":"","annotations":[]}
                })));
                self.blocks.insert(
                    source_index,
                    StreamBlock {
                        kind: StreamBlockKind::Text,
                        output_index,
                        item_id,
                        call_id: String::new(),
                        name: String::new(),
                        accum: block
                            .get("text")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                        start_input: String::new(),
                        source_block: block.clone(),
                        has_visible_summary: false,
                        done: false,
                    },
                );
            }
            "tool_use" => {
                let output_index = self.next_output_index();
                let call_id = block
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let name = block
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let item_id = self.tool_context.response_item_id(
                    &name,
                    &self.response_id,
                    output_index as usize,
                );
                let start_input = block
                    .get("input")
                    .filter(|value| value.as_object().is_some_and(|object| !object.is_empty()))
                    .map(canonical_json_string)
                    .unwrap_or_default();
                let mut item = self.tool_context.response_tool_item(
                    &item_id,
                    "in_progress",
                    &call_id,
                    &name,
                    "",
                );
                if item.get("type").and_then(Value::as_str) == Some("function_call") {
                    item["arguments"] = json!("");
                }
                out.push_str(&sse_event(&json!({
                    "type":"response.output_item.added","output_index":output_index,"item":item
                })));
                self.blocks.insert(
                    source_index,
                    StreamBlock {
                        kind: StreamBlockKind::Tool,
                        output_index,
                        item_id,
                        call_id,
                        name,
                        accum: String::new(),
                        start_input,
                        source_block: block.clone(),
                        has_visible_summary: false,
                        done: false,
                    },
                );
            }
            "thinking" | "redacted_thinking" => {
                let output_index = self.next_output_index();
                let item_id = format!(
                    "rs_{}_{}",
                    self.response_id.trim_start_matches("resp_"),
                    output_index
                );
                out.push_str(&sse_event(&json!({
                    "type":"response.output_item.added","output_index":output_index,
                    "item":{"id":item_id,"type":"reasoning","status":"in_progress","summary":[]}
                })));
                let has_visible_summary = block_type == "thinking";
                if has_visible_summary {
                    out.push_str(&sse_event(&json!({
                        "type":"response.reasoning_summary_part.added","item_id":item_id,
                        "output_index":output_index,"summary_index":0,
                        "part":{"type":"summary_text","text":""}
                    })));
                }
                self.blocks.insert(
                    source_index,
                    StreamBlock {
                        kind: StreamBlockKind::Thinking,
                        output_index,
                        item_id,
                        call_id: String::new(),
                        name: String::new(),
                        accum: block
                            .get("thinking")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                        start_input: String::new(),
                        source_block: block.clone(),
                        has_visible_summary,
                        done: false,
                    },
                );
            }
            _ => {}
        }
        out
    }

    fn handle_block_delta(&mut self, event: &Value) -> String {
        let Some(source_index) = event.get("index").and_then(Value::as_u64) else {
            return String::new();
        };
        let delta = event.get("delta").unwrap_or(&Value::Null);
        let delta_type = delta.get("type").and_then(Value::as_str).unwrap_or("");
        let Some(block) = self.blocks.get_mut(&source_index) else {
            return String::new();
        };
        match delta_type {
            "text_delta" if block.kind == StreamBlockKind::Text => {
                let text = delta.get("text").and_then(Value::as_str).unwrap_or("");
                block.accum.push_str(text);
                sse_event(&json!({
                    "type":"response.output_text.delta","item_id":block.item_id,
                    "output_index":block.output_index,"content_index":0,"delta":text
                }))
            }
            "input_json_delta" if block.kind == StreamBlockKind::Tool => {
                let partial = delta
                    .get("partial_json")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                block.accum.push_str(partial);
                if block.name == "Read"
                    || self.tool_context.kind_for_chat_name(&block.name)
                        == crate::protocol::openai_responses::CodexToolKind::Custom
                {
                    String::new()
                } else {
                    sse_event(&json!({
                        "type":"response.function_call_arguments.delta","item_id":block.item_id,
                        "output_index":block.output_index,"delta":partial
                    }))
                }
            }
            "thinking_delta" if block.kind == StreamBlockKind::Thinking => {
                let thinking = delta.get("thinking").and_then(Value::as_str).unwrap_or("");
                block.accum.push_str(thinking);
                block.source_block["thinking"] = json!(block.accum);
                sse_event(&json!({
                    "type":"response.reasoning_summary_text.delta","item_id":block.item_id,
                    "output_index":block.output_index,"summary_index":0,"delta":thinking
                }))
            }
            "signature_delta" if block.kind == StreamBlockKind::Thinking => {
                if let Some(signature) = delta.get("signature").and_then(Value::as_str) {
                    block.source_block["signature"] = json!(signature);
                }
                String::new()
            }
            _ => String::new(),
        }
    }

    fn close_block(&mut self, source_index: u64) -> String {
        let Some(block) = self.blocks.get_mut(&source_index) else {
            return String::new();
        };
        if block.done {
            return String::new();
        }
        block.done = true;
        let output_index = block.output_index;
        let item_id = block.item_id.clone();
        let mut out = String::new();
        let item = match block.kind {
            StreamBlockKind::Text => {
                let text = block.accum.clone();
                out.push_str(&sse_event(&json!({
                    "type":"response.output_text.done","item_id":item_id,
                    "output_index":output_index,"content_index":0,"text":text
                })));
                out.push_str(&sse_event(&json!({
                    "type":"response.content_part.done","item_id":item_id,
                    "output_index":output_index,"content_index":0,
                    "part":{"type":"output_text","text":text,"annotations":[]}
                })));
                json!({
                    "id":item_id,"type":"message","status":"completed","role":"assistant",
                    "content":[{"type":"output_text","text":text,"annotations":[]}]
                })
            }
            StreamBlockKind::Tool => {
                let raw = if block.accum.trim().is_empty() {
                    block.start_input.as_str()
                } else {
                    block.accum.as_str()
                };
                let arguments = canonical_tool_arguments(&block.name, raw);
                let status = if self.stream_truncated {
                    "incomplete"
                } else {
                    "completed"
                };
                let item = self.tool_context.response_tool_item(
                    &item_id,
                    status,
                    &block.call_id,
                    &block.name,
                    &arguments,
                );
                if !self.stream_truncated {
                    if self.tool_context.kind_for_chat_name(&block.name)
                        == crate::protocol::openai_responses::CodexToolKind::Custom
                    {
                        let input = item.get("input").and_then(Value::as_str).unwrap_or("");
                        out.push_str(&sse_event(&json!({
                            "type":"response.custom_tool_call_input.done","item_id":item_id,
                            "output_index":output_index,"input":input
                        })));
                    } else {
                        out.push_str(&sse_event(&json!({
                            "type":"response.function_call_arguments.done","item_id":item_id,
                            "output_index":output_index,"arguments":arguments
                        })));
                    }
                }
                item
            }
            StreamBlockKind::Thinking => {
                if block.source_block.get("type").and_then(Value::as_str) == Some("thinking") {
                    block.source_block["thinking"] = json!(block.accum);
                }
                let Some(item) =
                    responses_reasoning_item_from_anthropic_block(&item_id, &block.source_block)
                else {
                    // A missing signature is never upgraded into replayable reasoning.
                    return String::new();
                };
                if block.has_visible_summary {
                    out.push_str(&sse_event(&json!({
                        "type":"response.reasoning_summary_text.done","item_id":item_id,
                        "output_index":output_index,"summary_index":0,"text":block.accum
                    })));
                    out.push_str(&sse_event(&json!({
                        "type":"response.reasoning_summary_part.done","item_id":item_id,
                        "output_index":output_index,"summary_index":0,
                        "part":{"type":"summary_text","text":block.accum}
                    })));
                }
                item
            }
        };
        out.push_str(&sse_event(&json!({
            "type":"response.output_item.done","output_index":output_index,"item":item
        })));
        self.output_items.push((output_index, item));
        out
    }

    fn has_substantive_output(&self) -> bool {
        !self.output_items.is_empty()
            || self.blocks.values().any(|block| {
                !block.accum.trim().is_empty()
                    || !block.call_id.trim().is_empty()
                    || !block.name.trim().is_empty()
                    || block.source_block.get("data").is_some()
            })
    }

    fn finalize(&mut self) -> String {
        if self.completed {
            return String::new();
        }
        let mut out = self.ensure_started();
        let open = self
            .blocks
            .iter()
            .filter_map(|(index, block)| (!block.done).then_some(*index))
            .collect::<Vec<_>>();
        for index in open {
            out.push_str(&self.close_block(index));
        }
        let mut output = self.output_items.clone();
        output.sort_by_key(|(index, _)| *index);
        let output = output.into_iter().map(|(_, item)| item).collect();
        let (status, reason) = match self.stop_reason.as_deref() {
            Some("max_tokens" | "model_context_window_exceeded") => {
                ("incomplete", Some("max_output_tokens"))
            }
            Some("refusal") => ("incomplete", Some("content_filter")),
            _ => ("completed", None),
        };
        let mut response = self.base_response(status, output);
        if let Some(reason) = reason {
            response["incomplete_details"] = json!({"reason":reason});
        }
        let event_type = if status == "incomplete" {
            "response.incomplete"
        } else {
            "response.completed"
        };
        out.push_str(&sse_event(&json!({"type":event_type,"response":response})));
        self.completed = true;
        out
    }

    fn failed_event(&mut self, message: &str, error_type: &str) -> String {
        if self.completed {
            return String::new();
        }
        let mut out = self.ensure_started();
        let mut output = self.output_items.clone();
        output.sort_by_key(|(index, _)| *index);
        let output = output.into_iter().map(|(_, item)| item).collect();
        let mut response = self.base_response("failed", output);
        response["error"] = json!({"type":error_type,"message":message});
        out.push_str(&sse_event(
            &json!({"type":"response.failed","response":response}),
        ));
        self.completed = true;
        out
    }

    /// Feed one complete raw SSE line. `data:` JSON drives the state machine; `event:` and blank
    /// lines are intentionally ignored because Anthropic repeats the event type in the payload.
    pub fn push(&mut self, line: &str) -> String {
        if self.completed {
            return String::new();
        }
        let Some(payload) = line.trim().strip_prefix("data:").map(str::trim) else {
            return String::new();
        };
        if payload.is_empty() || payload == "[DONE]" {
            return String::new();
        }
        let Ok(event) = serde_json::from_str::<Value>(payload) else {
            return String::new();
        };
        match event.get("type").and_then(Value::as_str).unwrap_or("") {
            "message_start" => self.handle_message_start(&event),
            "content_block_start" => self.handle_block_start(&event),
            "content_block_delta" => self.handle_block_delta(&event),
            "content_block_stop" => {
                let index = event.get("index").and_then(Value::as_u64).unwrap_or(0);
                self.close_block(index)
            }
            "message_delta" => {
                if let Some(reason) = event.pointer("/delta/stop_reason").and_then(Value::as_str) {
                    self.stop_reason = Some(reason.to_string());
                }
                if let Some(usage) = event.get("usage") {
                    self.merge_usage(usage);
                }
                String::new()
            }
            "message_stop" => self.finalize(),
            "error" => {
                let error = event.get("error").unwrap_or(&event);
                let message = error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("upstream Anthropic SSE error");
                let error_type = error
                    .get("type")
                    .and_then(Value::as_str)
                    .unwrap_or("upstream_error");
                self.failed_event(message, error_type)
            }
            _ => String::new(),
        }
    }

    pub fn finish(&mut self) -> String {
        if self.completed {
            return String::new();
        }
        if self.stop_reason.is_some() {
            return self.finalize();
        }
        if self.has_substantive_output() {
            self.stop_reason = Some("max_tokens".to_string());
            self.stream_truncated = true;
            return self.finalize();
        }
        self.failed_event(
            "Upstream Anthropic stream ended before message_stop",
            "stream_truncated",
        )
    }

    pub fn fail(&mut self, message: &str) -> String {
        self.failed_event(message, "stream_error")
    }
}

fn canonical_json_string(value: &Value) -> String {
    match value {
        Value::Null => "null".to_string(),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        Value::String(value) => serde_json::to_string(value).unwrap_or_default(),
        Value::Array(values) => format!(
            "[{}]",
            values
                .iter()
                .map(canonical_json_string)
                .collect::<Vec<_>>()
                .join(",")
        ),
        Value::Object(object) => {
            let mut entries = object.iter().collect::<Vec<_>>();
            entries.sort_by_key(|(key, _)| *key);
            format!(
                "{{{}}}",
                entries
                    .into_iter()
                    .map(|(key, value)| format!(
                        "{}:{}",
                        serde_json::to_string(key).unwrap_or_default(),
                        canonical_json_string(value)
                    ))
                    .collect::<Vec<_>>()
                    .join(",")
            )
        }
    }
}

fn canonical_tool_arguments(name: &str, raw: &str) -> String {
    if raw.trim().is_empty() {
        return "{}".to_string();
    }
    let Ok(mut value) = serde_json::from_str::<Value>(raw) else {
        return raw.to_string();
    };
    if name == "Read" {
        if let Some(object) = value.as_object_mut() {
            if object.get("pages").and_then(Value::as_str) == Some("") {
                object.remove("pages");
            }
        }
    }
    canonical_json_string(&value)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signed_block() -> Value {
        json!({"type":"thinking","thinking":"inspect first","signature":"sig_123"})
    }

    fn envelope(block: &Value) -> String {
        encode_anthropic_thinking_block(block).unwrap()
    }

    #[test]
    fn envelope_round_trips_only_authenticated_blocks() {
        let thinking = signed_block();
        assert_eq!(
            decode_anthropic_thinking_block(&envelope(&thinking)),
            Some(thinking)
        );
        let redacted = json!({"type":"redacted_thinking","data":"opaque"});
        assert_eq!(
            decode_anthropic_thinking_block(&envelope(&redacted)),
            Some(redacted)
        );
        assert!(
            encode_anthropic_thinking_block(&json!({"type":"thinking","thinking":"unsigned"}))
                .is_none()
        );
        assert!(
            encode_anthropic_thinking_block(&json!({"type":"redacted_thinking","data":""}))
                .is_none()
        );
        assert!(decode_anthropic_thinking_block("foreign-ciphertext").is_none());
    }

    #[test]
    fn request_replays_signed_thinking_on_the_exact_tool_turn() {
        let request = json!({
            "reasoning":{"effort":"high"},
            "input":[
                {"type":"message","role":"user","content":"inspect"},
                {"type":"reasoning","encrypted_content":envelope(&signed_block()),
                 "summary":[{"type":"summary_text","text":"inspect first"}]},
                {"type":"function_call","call_id":"call_1","name":"read","arguments":"{}"},
                {"type":"function_call_output","call_id":"call_1","output":"ok"}
            ]
        });
        let mut anthropic = json!({
            "max_tokens":8192,
            "thinking":{"type":"enabled","budget_tokens":4096},
            "messages":[
                {"role":"user","content":[{"type":"text","text":"inspect"}]},
                {"role":"assistant","content":[
                    {"type":"thinking","thinking":"lossy unsigned summary"},
                    {"type":"tool_use","id":"call_1","name":"read","input":{}}
                ]},
                {"role":"user","content":[
                    {"type":"tool_result","tool_use_id":"call_1","content":"ok"}
                ]}
            ]
        });
        patch_anthropic_request(&request, &mut anthropic).unwrap();
        assert_eq!(anthropic["messages"][1]["content"][0], signed_block());
        assert_eq!(anthropic["thinking"]["type"], "enabled");
        // high=16384, capped to half the 8192 output ceiling.
        assert_eq!(anthropic["thinking"]["budget_tokens"], 4096);
    }

    #[test]
    fn malformed_or_old_signature_cannot_enable_a_new_tool_turn() {
        let old = signed_block();
        let request = json!({
            "reasoning":{"effort":"high"},
            "input":[
                {"type":"reasoning","encrypted_content":envelope(&old)},
                {"type":"function_call","call_id":"old_call","name":"read","arguments":"{}"},
                {"type":"function_call_output","call_id":"old_call","output":"ok"},
                {"type":"function_call","call_id":"new_call","name":"read","arguments":"{}"},
                {"type":"function_call_output","call_id":"new_call","output":"ok"}
            ]
        });
        let mut anthropic = json!({
            "max_tokens":8192,
            "thinking":{"type":"enabled","budget_tokens":4096},
            "messages":[
                {"role":"user","content":[{"type":"text","text":"continue"}]},
                {"role":"assistant","content":[{"type":"tool_use","id":"old_call","name":"read","input":{}}]},
                {"role":"user","content":[{"type":"tool_result","tool_use_id":"old_call","content":"ok"}]},
                {"role":"assistant","content":[{"type":"tool_use","id":"new_call","name":"read","input":{}}]},
                {"role":"user","content":[{"type":"tool_result","tool_use_id":"new_call","content":"ok"}]}
            ]
        });
        patch_anthropic_request(&request, &mut anthropic).unwrap();
        assert_eq!(anthropic["messages"][1]["content"][0], old);
        assert!(anthropic.get("thinking").is_none());
    }

    #[test]
    fn adaptive_and_cannot_disable_model_boundaries_match_cc_switch() {
        let request = json!({
            "reasoning":{"effort":"high"},
            "input":[{"type":"message","role":"user","content":"hello"}],
            "temperature":0.4
        });
        let mut adaptive = json!({
            "model":"anthropic.claude-sonnet-4-6-20250514-v1:0",
            "messages":[{"role":"user","content":[{"type":"text","text":"hello"}]}]
        });
        patch_anthropic_request(&request, &mut adaptive).unwrap();
        assert_eq!(adaptive["thinking"], json!({"type":"adaptive"}));
        assert_eq!(adaptive["output_config"], json!({"effort":"high"}));
        assert!(adaptive.get("temperature").is_none());

        adaptive["tool_choice"] = json!({"type":"tool","name":"read"});
        patch_anthropic_request(&request, &mut adaptive).unwrap();
        assert_eq!(adaptive["thinking"], json!({"type":"disabled"}));
        assert!(adaptive.get("output_config").is_none());
        assert_eq!(adaptive["temperature"], 0.4);

        let missing_signature = json!({
            "reasoning":{"effort":"none"},
            "input":[
                {"type":"function_call","call_id":"call_1","name":"read","arguments":"{}"},
                {"type":"function_call_output","call_id":"call_1","output":"ok"}
            ]
        });
        let mut fable = json!({
            "model":"claude-fable-5",
            "messages":[
                {"role":"assistant","content":[{"type":"tool_use","id":"call_1","name":"read","input":{}}]},
                {"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"ok"}]}
            ]
        });
        let error = patch_anthropic_request(&missing_signature, &mut fable).unwrap_err();
        assert!(error.contains("no signed thinking block"));
    }

    #[test]
    fn foreign_ciphertext_is_never_replayed_from_a_visible_summary() {
        let request = json!({
            "reasoning":{"effort":"high"},
            "input":[
                {"type":"reasoning","encrypted_content":"provider-opaque",
                 "summary":[{"type":"summary_text","text":"visible only"}]},
                {"type":"function_call","call_id":"call_1","name":"read","arguments":"{}"},
                {"type":"function_call_output","call_id":"call_1","output":"ok"}
            ]
        });
        let mut anthropic = json!({
            "model":"claude-legacy","thinking":{"type":"enabled","budget_tokens":4096},
            "messages":[
                {"role":"assistant","content":[
                    {"type":"thinking","thinking":"visible only"},
                    {"type":"tool_use","id":"call_1","name":"read","input":{}}
                ]},
                {"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"ok"}]}
            ]
        });
        patch_anthropic_request(&request, &mut anthropic).unwrap();
        assert_eq!(anthropic["messages"][0]["content"][0]["type"], "tool_use");
        assert!(anthropic.get("thinking").is_none());
    }

    #[test]
    fn response_preserves_signed_and_redacted_thinking_but_drops_unsigned() {
        let source = json!({
            "stop_reason":"tool_use",
            "content":[
                signed_block(),
                {"type":"redacted_thinking","data":"opaque"},
                {"type":"thinking","thinking":"unsigned"},
                {"type":"tool_use","id":"call_1","name":"read","input":{}}
            ],
            "usage":{
                "input_tokens":4,"cache_read_input_tokens":2,
                "cache_creation_input_tokens":1,"output_tokens":3,
                "output_tokens_details":{"thinking_tokens":2}
            }
        });
        let mut response = json!({
            "id":"resp_1","status":"completed","model":"client","output":[
                {"type":"reasoning","id":"lossy","summary":[{"type":"summary_text","text":"unsigned"}]},
                {"type":"function_call","id":"fc_1","call_id":"call_1","name":"read",
                 "arguments":"{}","reasoning_content":"inspect first"}
            ]
        });
        patch_responses_response(&source, &mut response).unwrap();
        let output = response["output"].as_array().unwrap();
        assert_eq!(output.len(), 3);
        assert_eq!(output[0]["summary"][0]["text"], "inspect first");
        assert!(output[0]["encrypted_content"]
            .as_str()
            .unwrap()
            .starts_with(ANTHROPIC_THINKING_ENCRYPTED_PREFIX));
        assert_eq!(output[1]["summary"], json!([]));
        assert!(output[2].get("reasoning_content").is_none());
        assert_eq!(response["usage"]["input_tokens"], 7);
        assert_eq!(
            response["usage"]["input_tokens_details"]["cached_tokens"],
            2
        );
        assert_eq!(
            response["usage"]["output_tokens_details"]["reasoning_tokens"],
            2
        );
    }

    #[test]
    fn synthesized_sse_keeps_encrypted_reasoning_in_done_and_terminal_items() {
        let encrypted = envelope(&signed_block());
        let response = json!({
            "id":"resp_1","object":"response","status":"completed","model":"client",
            "output":[{
                "type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"think"}],
                "encrypted_content":encrypted
            }],
            "usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}
        });
        let sse = responses_json_to_sse(&response).unwrap();
        assert!(sse.contains("event: response.reasoning_summary_text.delta"));
        assert_eq!(sse.matches(ANTHROPIC_THINKING_ENCRYPTED_PREFIX).count(), 2);
        assert!(sse.contains("event: response.completed"));
    }

    #[test]
    fn live_redacted_thinking_has_an_opaque_reasoning_lifecycle() {
        let mut stream = SignedAnthropicToResponsesStream::new(
            "client-model",
            crate::protocol::openai_responses::CodexToolContext::default(),
        );
        let mut output = String::new();
        for line in [
            r#"data: {"type":"message_start","message":{"id":"msg_redacted"}}"#,
            r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"opaque"}}"#,
            r#"data: {"type":"content_block_stop","index":0}"#,
            r#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            r#"data: {"type":"message_stop"}"#,
        ] {
            output.push_str(&stream.push(line));
        }
        assert!(output.contains("response.output_item.added"));
        assert!(!output.contains("response.reasoning_summary_part.added"));
        assert!(!output.contains("response.reasoning_summary_text.delta"));
        assert_eq!(
            output.matches(ANTHROPIC_THINKING_ENCRYPTED_PREFIX).count(),
            2
        );
        assert!(output.contains("event: response.completed"));
    }
}
