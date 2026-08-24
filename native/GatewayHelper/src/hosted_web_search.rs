//! Anthropic hosted WebSearch <-> OpenAI Responses bridge.
//!
//! This is intentionally kept at the gateway edge rather than in the shared generic codec:
//! hosted server tools are not client-executed functions, and flattening them through the
//! connector IR loses call/result pairing, citations, caller metadata, and usage accounting.

use crate::citation_renderer::output_text_with_url_citations;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};

const SOURCES_INCLUDE: &str = "web_search_call.action.sources";
const TOOL_RESULT_ERROR_MARKER: &str = "[cc-switch:tool-result-error]";
const TOOL_RESULT_MEDIA_ATTACHED_MARKER: &str =
    "[cc-switch: tool result media attached as native media]";
const OPENAI_REASONING_ITEM_PREFIX: &str = "ccswitch-openai-reasoning-v1:";
const WHOLE_DATA_URL_MIN_BYTES: usize = 8 * 1024;
const BASE64ISH_MIN_BYTES: usize = 16 * 1024;
const MAX_MEDIA_TRAVERSAL_DEPTH: usize = 32;

#[derive(Clone, Debug)]
struct HostedTool {
    name: String,
    response_tool: Value,
    max_uses: Option<u64>,
}

#[derive(Clone, Debug)]
pub struct HostedWebSearchBridge {
    tool_name: String,
    max_uses: Option<u64>,
    tools: Vec<HostedTool>,
    hosted_names: HashSet<String>,
}

impl HostedWebSearchBridge {
    pub fn from_anthropic_request(body: &Value) -> Result<Option<Self>, String> {
        let tools = body
            .get("tools")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or_default();
        let forced_name = body
            .get("tool_choice")
            .and_then(Value::as_object)
            .filter(|choice| choice.get("type").and_then(Value::as_str) == Some("tool"))
            .and_then(|choice| choice.get("name"))
            .and_then(Value::as_str);

        let mut hosted_tools = Vec::new();
        for tool in tools.iter().filter(|tool| is_hosted_tool(tool)) {
            hosted_tools.push(parse_hosted_tool(tool)?);
        }

        let mut history_names = Vec::new();
        if let Some(messages) = body.get("messages").and_then(Value::as_array) {
            for message in messages {
                let Some(blocks) = message.get("content").and_then(Value::as_array) else {
                    continue;
                };
                for block in blocks {
                    if block.get("type").and_then(Value::as_str) == Some("server_tool_use") {
                        if let Some(name) = block
                            .get("name")
                            .and_then(Value::as_str)
                            .filter(|name| *name == "web_search" || name.starts_with("web_search_"))
                        {
                            history_names.push(name.to_string());
                        }
                    }
                }
            }
        }

        if hosted_tools.is_empty() && history_names.is_empty() {
            return Ok(None);
        }

        let hosted_names: HashSet<String> = hosted_tools
            .iter()
            .map(|tool| tool.name.clone())
            .chain(history_names.iter().cloned())
            .collect();
        let selected_name = forced_name
            .filter(|name| hosted_names.contains(*name))
            .map(str::to_string)
            .or_else(|| hosted_tools.first().map(|tool| tool.name.clone()))
            .or_else(|| history_names.first().cloned())
            .unwrap_or_else(|| "web_search".to_string());
        let max_uses = hosted_tools
            .iter()
            .filter(|tool| forced_name.is_none_or(|name| tool.name == name))
            .filter_map(|tool| tool.max_uses)
            .min();

        Ok(Some(Self {
            tool_name: selected_name,
            max_uses,
            tools: hosted_tools,
            hosted_names,
        }))
    }

    pub fn request_for_generic_codec(&self, original: &Value) -> Value {
        let mut request = original.clone();
        if let Some(tools) = request.get_mut("tools").and_then(Value::as_array_mut) {
            tools.retain(|tool| !is_hosted_tool(tool));
        }
        request
    }

    pub fn apply_to_responses_request(
        &self,
        original: &Value,
        encoded: &mut Value,
    ) -> Result<(), String> {
        let encoded_object = encoded
            .as_object_mut()
            .ok_or_else(|| "Responses request must be a JSON object".to_string())?;

        if let Some(messages) = original.get("messages").and_then(Value::as_array) {
            encoded_object.insert(
                "input".to_string(),
                Value::Array(convert_messages_to_input(messages, &self.hosted_names)),
            );
        }

        let existing_functions = encoded_object
            .remove("tools")
            .and_then(|value| value.as_array().cloned())
            .unwrap_or_default();
        let mut functions_by_name: HashMap<String, Vec<Value>> = HashMap::new();
        for function in existing_functions {
            if let Some(name) = function.get("name").and_then(Value::as_str) {
                functions_by_name
                    .entry(name.to_string())
                    .or_default()
                    .push(function);
            }
        }

        let mut response_tools = Vec::new();
        if let Some(original_tools) = original.get("tools").and_then(Value::as_array) {
            for original_tool in original_tools {
                if is_hosted_tool(original_tool) {
                    let name = original_tool
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("web_search");
                    if let Some(hosted) = self.tools.iter().find(|tool| tool.name == name) {
                        response_tools.push(hosted.response_tool.clone());
                    }
                } else if let Some(name) = original_tool.get("name").and_then(Value::as_str) {
                    if let Some(functions) = functions_by_name.get_mut(name) {
                        if !functions.is_empty() {
                            response_tools.push(functions.remove(0));
                        }
                    }
                }
            }
        }
        if !response_tools.is_empty() {
            encoded_object.insert("tools".to_string(), Value::Array(response_tools));
        }

        if let Some(tool_choice) = original.get("tool_choice") {
            encoded_object.insert(
                "tool_choice".to_string(),
                map_tool_choice(tool_choice, &self.hosted_names),
            );
        }
        if let Some(max_uses) = self.max_uses {
            encoded_object.insert("max_tool_calls".to_string(), json!(max_uses));
        }

        let include = encoded_object
            .entry("include".to_string())
            .or_insert_with(|| Value::Array(Vec::new()));
        let includes = include
            .as_array_mut()
            .ok_or_else(|| "Responses include must be an array".to_string())?;
        if !includes
            .iter()
            .any(|value| value.as_str() == Some(SOURCES_INCLUDE))
        {
            includes.push(json!(SOURCES_INCLUDE));
        }
        Ok(())
    }

    pub fn responses_to_anthropic(&self, body: Value, client_model: &str) -> Result<Value, String> {
        responses_to_anthropic(body, &self.tool_name, self.max_uses, client_model)
    }
}

fn is_hosted_tool(tool: &Value) -> bool {
    tool.get("type")
        .and_then(Value::as_str)
        .is_some_and(|kind| kind == "web_search" || kind.starts_with("web_search_"))
}

fn parse_hosted_tool(tool: &Value) -> Result<HostedTool, String> {
    let kind = tool
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("web_search");
    let defaults_to_direct = match kind {
        "web_search" | "web_search_20250305" => true,
        "web_search_20260209" | "web_search_20260318" => false,
        _ => {
            return Err(format!(
                "Anthropic WebSearch version '{kind}' is not supported by the Responses bridge"
            ))
        }
    };
    if tool.get("response_inclusion").is_some() {
        return Err(
            "Anthropic WebSearch response_inclusion cannot be represented by the Responses bridge"
                .to_string(),
        );
    }
    match tool.get("allowed_callers") {
        None if defaults_to_direct => {}
        None => {
            return Err(format!(
                "Anthropic WebSearch version '{kind}' defaults to code execution; set allowed_callers to [\"direct\"] for the Responses bridge"
            ))
        }
        Some(Value::Array(callers))
            if callers.len() == 1 && callers[0].as_str() == Some("direct") => {}
        Some(_) => {
            return Err(
                "Anthropic WebSearch allowed_callers must be exactly [\"direct\"] for the Responses bridge"
                    .to_string(),
            )
        }
    }
    if tool
        .get("blocked_domains")
        .and_then(Value::as_array)
        .is_some_and(|domains| !domains.is_empty())
    {
        return Err(
            "Anthropic WebSearch blocked_domains cannot be represented by the Responses API"
                .to_string(),
        );
    }
    let max_uses = match tool.get("max_uses") {
        None | Some(Value::Null) => None,
        Some(value) => Some(value.as_u64().filter(|limit| *limit > 0).ok_or_else(|| {
            "Anthropic WebSearch max_uses must be a positive integer".to_string()
        })?),
    };
    let mut response_tool = json!({"type": "web_search"});
    if let Some(allowed_domains) = tool
        .get("allowed_domains")
        .and_then(Value::as_array)
        .filter(|domains| !domains.is_empty())
    {
        response_tool["filters"] = json!({"allowed_domains": allowed_domains});
    }
    if let Some(location) = tool.get("user_location").filter(|value| value.is_object()) {
        response_tool["user_location"] = location.clone();
    }
    Ok(HostedTool {
        name: tool
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("web_search")
            .to_string(),
        response_tool,
        max_uses,
    })
}

fn map_tool_choice(choice: &Value, hosted_names: &HashSet<String>) -> Value {
    match choice {
        Value::String(_) => choice.clone(),
        Value::Object(object) => match object.get("type").and_then(Value::as_str) {
            Some("any") => json!("required"),
            Some("auto") => json!("auto"),
            Some("none") => json!("none"),
            Some("tool") => {
                let name = object.get("name").and_then(Value::as_str).unwrap_or("");
                if hosted_names.contains(name) {
                    json!({"type":"web_search"})
                } else {
                    json!({"type":"function", "name":name})
                }
            }
            _ => choice.clone(),
        },
        _ => choice.clone(),
    }
}

fn flush_message(input: &mut Vec<Value>, role: &str, content: &mut Vec<Value>) {
    if content.is_empty() {
        return;
    }
    input.push(json!({"role": role, "content": std::mem::take(content)}));
}

fn convert_messages_to_input(messages: &[Value], hosted_names: &HashSet<String>) -> Vec<Value> {
    let paired_results = collect_hosted_results(messages);
    let mut input = Vec::new();
    for message in messages {
        let role = message
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or("user");
        let message_input_start = input.len();
        match message.get("content") {
            Some(Value::String(text)) => input.push(json!({
                "role": role,
                "content": [{"type": if role == "assistant" {"output_text"} else {"input_text"}, "text": text}]
            })),
            Some(Value::Array(blocks)) => {
                let mut content = Vec::new();
                for block in blocks {
                    match block.get("type").and_then(Value::as_str).unwrap_or("") {
                        "text" | "input_text" => {
                            if let Some(text) = block.get("text").and_then(Value::as_str) {
                                content.push(json!({
                                    "type": if role == "assistant" {"output_text"} else {"input_text"},
                                    "text": text
                                }));
                            }
                        }
                        "image" => {
                            if let Some(image) = anthropic_image_to_responses(block) {
                                content.push(image);
                            }
                        }
                        "document" => {
                            if let Some(document) = anthropic_document_to_responses(block) {
                                content.push(document);
                            }
                        }
                        "tool_use" => {
                            flush_message(&mut input, role, &mut content);
                            let arguments = block.get("input").cloned().unwrap_or_else(|| json!({}));
                            input.push(json!({
                                "type":"function_call",
                                "call_id":block.get("id").cloned().unwrap_or_else(|| json!("")),
                                "name":block.get("name").cloned().unwrap_or_else(|| json!("")),
                                "arguments":serde_json::to_string(&arguments).unwrap_or_else(|_| "{}".to_string())
                            }));
                        }
                        "tool_result" => {
                            flush_message(&mut input, role, &mut content);
                            input.push(json!({
                                "type":"function_call_output",
                                "call_id":block.get("tool_use_id").cloned().unwrap_or_else(|| json!("")),
                                "output":anthropic_tool_result_output(block)
                            }));
                        }
                        "server_tool_use" => {
                            let name = block.get("name").and_then(Value::as_str).unwrap_or("");
                            let id = block.get("id").and_then(Value::as_str).unwrap_or("");
                            if hosted_names.contains(name) {
                                if let Some(result) = paired_results.get(id) {
                                    flush_message(&mut input, role, &mut content);
                                    input.push(web_search_call_from_blocks(block, result));
                                }
                            }
                        }
                        "web_search_tool_result" => {}
                        "thinking" | "redacted_thinking" => {
                            if let Some(reasoning) =
                                openai_reasoning_item_from_anthropic_block(block)
                            {
                                flush_message(&mut input, role, &mut content);
                                input.push(reasoning);
                            }
                        }
                        _ => {}
                    }
                }
                flush_message(&mut input, role, &mut content);
            }
            _ => input.push(json!({"role":role})),
        }

        // Responses rejects a replayed reasoning item unless the same assistant generation also
        // contains a following message or tool call. Preserve cc-switch's fail-safe pruning for
        // reasoning-only incomplete turns.
        if role == "assistant" {
            let mut has_generated_follower = false;
            for index in (message_input_start..input.len()).rev() {
                let item_type = input[index].get("type").and_then(Value::as_str);
                let is_assistant_message =
                    input[index].get("role").and_then(Value::as_str) == Some("assistant");
                if item_type == Some("reasoning") {
                    if !has_generated_follower {
                        input.remove(index);
                    }
                } else if matches!(item_type, Some("function_call" | "web_search_call"))
                    || is_assistant_message
                {
                    has_generated_follower = true;
                }
            }
        }
    }
    input
}

fn collect_hosted_results(messages: &[Value]) -> HashMap<String, Value> {
    let mut results = HashMap::new();
    for message in messages {
        let Some(blocks) = message.get("content").and_then(Value::as_array) else {
            continue;
        };
        for block in blocks {
            if block.get("type").and_then(Value::as_str) == Some("web_search_tool_result") {
                if let Some(id) = block
                    .get("tool_use_id")
                    .and_then(Value::as_str)
                    .filter(|id| !id.is_empty())
                {
                    results.insert(id.to_string(), block.clone());
                }
            }
        }
    }
    results
}

fn anthropic_image_to_responses(block: &Value) -> Option<Value> {
    let source = block.get("source")?;
    match source.get("type").and_then(Value::as_str) {
        Some("url") => source
            .get("url")
            .and_then(Value::as_str)
            .filter(|url| has_http_url_scheme(url))
            .map(|url| json!({"type":"input_image", "image_url":url})),
        Some("base64") | None => {
            let data = source
                .get("data")
                .and_then(Value::as_str)
                .filter(|data| !data.is_empty())?;
            let media_type = source
                .get("media_type")
                .and_then(Value::as_str)
                .unwrap_or("image/png");
            Some(
                json!({"type":"input_image", "image_url":format!("data:{media_type};base64,{data}")}),
            )
        }
        _ => None,
    }
}

fn anthropic_document_to_responses(block: &Value) -> Option<Value> {
    let source = block.get("source")?;
    let filename = block
        .get("title")
        .or_else(|| block.get("filename"))
        .and_then(Value::as_str)
        .unwrap_or("document.pdf");
    match source.get("type").and_then(Value::as_str) {
        Some("url") => source
            .get("url")
            .and_then(Value::as_str)
            .filter(|url| has_http_url_scheme(url))
            .map(|url| json!({"type":"input_file", "file_url":url, "filename":filename})),
        Some("base64") => {
            let data = source
                .get("data")
                .and_then(Value::as_str)
                .filter(|data| !data.is_empty())?;
            let media_type = source
                .get("media_type")
                .and_then(Value::as_str)
                .unwrap_or("application/pdf");
            Some(json!({
                "type":"input_file",
                "file_data":format!("data:{media_type};base64,{data}"),
                "filename":filename
            }))
        }
        _ => None,
    }
}

fn anthropic_tool_result_output(block: &Value) -> Value {
    let is_error = block.get("is_error").and_then(Value::as_bool) == Some(true);
    let content = block.get("content");
    if !is_error {
        if let Some(text @ Value::String(_)) = content {
            if let Some(output) = alternate_image_tool_result_to_responses(text) {
                return Value::Array(output);
            }
            return text.clone();
        }
    }

    let mut output = Vec::new();
    if is_error {
        output.push(json!({"type":"input_text", "text":TOOL_RESULT_ERROR_MARKER}));
    }
    match content {
        Some(Value::String(text)) => {
            if let Some(mut alternate) =
                alternate_image_tool_result_to_responses(&Value::String(text.clone()))
            {
                output.append(&mut alternate);
            } else {
                output.push(json!({"type":"input_text", "text":text}));
            }
        }
        Some(Value::Array(parts)) => {
            for part in parts {
                match part.get("type").and_then(Value::as_str) {
                    Some("text" | "input_text" | "output_text") => {
                        if let Some(text) = part.get("text").and_then(Value::as_str) {
                            output.push(json!({"type":"input_text", "text":text}));
                        }
                    }
                    Some("image") => {
                        if let Some(image) = anthropic_image_to_responses(part) {
                            output.push(image);
                        } else if let Some(mut alternate) =
                            alternate_image_tool_result_to_responses(part)
                        {
                            output.append(&mut alternate);
                        } else {
                            output.push(
                                json!({"type":"input_text", "text":canonical_json_string(part)}),
                            );
                        }
                    }
                    Some("document") => {
                        output.push(anthropic_document_to_responses(part).unwrap_or_else(
                            || json!({"type":"input_text", "text":canonical_json_string(part)}),
                        ))
                    }
                    _ => {
                        if let Some(mut alternate) = alternate_image_tool_result_to_responses(part)
                        {
                            output.append(&mut alternate);
                        } else {
                            output.push(
                                json!({"type":"input_text", "text":canonical_json_string(part)}),
                            );
                        }
                    }
                }
            }
        }
        Some(value) => {
            if let Some(mut alternate) = alternate_image_tool_result_to_responses(value) {
                output.append(&mut alternate);
            } else {
                output.push(json!({"type":"input_text", "text":canonical_json_string(value)}));
            }
        }
        None => {}
    }
    Value::Array(output)
}

fn alternate_image_tool_result_to_responses(value: &Value) -> Option<Vec<Value>> {
    let mut cleaned = value.clone();
    let replacement_block = json!({
        "type":"input_text",
        "text":TOOL_RESULT_MEDIA_ATTACHED_MARKER
    });
    let mut chat_media_parts = Vec::new();
    let replaced = strip_and_clamp_image_media_from_tool_value(
        &mut cleaned,
        &mut chat_media_parts,
        &replacement_block,
        TOOL_RESULT_MEDIA_ATTACHED_MARKER,
    );
    if replaced == 0 {
        return None;
    }

    let mut output = Vec::new();
    append_sanitized_responses_tool_value(&cleaned, &mut output);
    output.extend(
        chat_media_parts
            .iter()
            .filter_map(responses_image_from_chat_media),
    );
    Some(output)
}

fn append_sanitized_responses_tool_value(value: &Value, output: &mut Vec<Value>) {
    match value {
        Value::String(text) if !text.is_empty() => {
            output.push(json!({"type":"input_text","text":text}));
        }
        Value::Array(parts) => {
            for part in parts {
                match part.get("type").and_then(Value::as_str) {
                    Some("input_text" | "output_text" | "text") => {
                        if let Some(text) = part.get("text").and_then(Value::as_str) {
                            output.push(json!({"type":"input_text","text":text}));
                        }
                    }
                    _ => output.push(json!({
                        "type":"input_text",
                        "text":canonical_json_string(part)
                    })),
                }
            }
        }
        Value::Object(object)
            if matches!(
                object.get("type").and_then(Value::as_str),
                Some("input_text" | "output_text" | "text")
            ) =>
        {
            if let Some(text) = object.get("text").and_then(Value::as_str) {
                output.push(json!({"type":"input_text","text":text}));
            }
        }
        Value::Null | Value::String(_) => {}
        other => output.push(json!({
            "type":"input_text",
            "text":canonical_json_string(other)
        })),
    }
}

fn responses_image_from_chat_media(part: &Value) -> Option<Value> {
    let image_url = part
        .pointer("/image_url/url")
        .and_then(Value::as_str)
        .filter(|url| !url.trim().is_empty())?;
    let mut image = json!({
        "type":"input_image",
        "image_url":image_url
    });
    if let Some(detail) = part.pointer("/image_url/detail") {
        image["detail"] = detail.clone();
    }
    Some(image)
}

fn strip_and_clamp_image_media_from_tool_value(
    value: &mut Value,
    media_parts: &mut Vec<Value>,
    replacement_block: &Value,
    replacement_text: &str,
) -> usize {
    let replaced = strip_image_media_from_tool_value_at_depth(
        value,
        media_parts,
        replacement_block,
        replacement_text,
        true,
        0,
    );
    if replaced > 0 {
        clamp_base64ish_strings(value);
    }
    replaced
}

fn strip_image_media_from_tool_value_at_depth(
    value: &mut Value,
    media_parts: &mut Vec<Value>,
    replacement_block: &Value,
    replacement_text: &str,
    clamp_parsed_strings: bool,
    depth: usize,
) -> usize {
    if depth > MAX_MEDIA_TRAVERSAL_DEPTH {
        return 0;
    }

    match value {
        Value::String(text) => {
            if let Some(media_part) = whole_string_image_data_url(text) {
                media_parts.push(media_part);
                *text = replacement_text.to_string();
                return 1;
            }

            let trimmed = text.trim();
            if trimmed.is_empty() {
                return 0;
            }
            let Ok(mut parsed) = serde_json::from_str::<Value>(trimmed) else {
                return 0;
            };
            let replaced = strip_image_media_from_tool_value_at_depth(
                &mut parsed,
                media_parts,
                replacement_block,
                replacement_text,
                clamp_parsed_strings,
                depth + 1,
            );
            if replaced > 0 {
                if clamp_parsed_strings {
                    clamp_base64ish_strings(&mut parsed);
                }
                *text = canonical_json_string(&parsed);
            }
            replaced
        }
        Value::Array(items) => items
            .iter_mut()
            .map(|item| {
                strip_image_media_from_tool_value_at_depth(
                    item,
                    media_parts,
                    replacement_block,
                    replacement_text,
                    clamp_parsed_strings,
                    depth + 1,
                )
            })
            .sum(),
        Value::Object(_) => {
            if let Some(media_part) = chat_image_part_from_tool_part(value) {
                media_parts.push(media_part);
                *value = replacement_block.clone();
                return 1;
            }

            value
                .as_object_mut()
                .expect("object match arm must remain an object")
                .get_mut("content")
                .map(|content| {
                    strip_image_media_from_tool_value_at_depth(
                        content,
                        media_parts,
                        replacement_block,
                        replacement_text,
                        clamp_parsed_strings,
                        depth + 1,
                    )
                })
                .unwrap_or(0)
        }
        _ => 0,
    }
}

fn whole_string_image_data_url(value: &str) -> Option<Value> {
    let trimmed = value.trim();
    if trimmed.len() < WHOLE_DATA_URL_MIN_BYTES || !is_image_base64_data_url(trimmed) {
        return None;
    }

    Some(json!({
        "type":"image_url",
        "image_url":{"url":trimmed}
    }))
}

fn chat_image_part_from_tool_part(part: &Value) -> Option<Value> {
    match part.get("type").and_then(Value::as_str) {
        Some("input_image" | "image_url") => normalized_image_url(part).map(image_url_content_part),
        Some("image") if typed_image_has_payload(part) => {
            typed_image_url(part).map(image_url_content_part)
        }
        None => loose_data_image_url(part).map(image_url_content_part),
        _ => None,
    }
}

fn normalized_image_url(part: &Value) -> Option<Value> {
    let image_url = part.get("image_url")?;
    let mut object = match image_url {
        Value::String(url) if !url.trim().is_empty() => {
            let mut object = Map::new();
            object.insert("url".to_string(), Value::String(url.clone()));
            object
        }
        Value::Object(object)
            if object
                .get("url")
                .and_then(Value::as_str)
                .is_some_and(|url| !url.trim().is_empty()) =>
        {
            object.clone()
        }
        _ => return None,
    };
    merge_top_level_detail(part, &mut object);
    Some(Value::Object(object))
}

fn loose_data_image_url(part: &Value) -> Option<Value> {
    if part.get("type").is_some() {
        return None;
    }
    let normalized = normalized_image_url(part)?;
    let url = normalized.get("url").and_then(Value::as_str)?;
    if !url
        .get(..5)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("data:"))
    {
        return None;
    }
    Some(normalized)
}

fn typed_image_has_payload(part: &Value) -> bool {
    let Some(object) = part.as_object() else {
        return false;
    };

    if let Some(source) = object.get("source").and_then(Value::as_object) {
        if source_media_type_is_image(source) {
            let has_url = source
                .get("url")
                .and_then(Value::as_str)
                .is_some_and(|url| !url.trim().is_empty());
            let has_data = source
                .get("data")
                .and_then(Value::as_str)
                .is_some_and(|data| !data.is_empty());
            if has_url || has_data {
                return true;
            }
        }
    }

    object
        .get("data")
        .and_then(Value::as_str)
        .is_some_and(|data| !data.is_empty())
        && object
            .get("mimeType")
            .or_else(|| object.get("mime_type"))
            .and_then(Value::as_str)
            .is_some_and(is_image_mime_type)
}

fn typed_image_url(part: &Value) -> Option<Value> {
    let object = part.as_object()?;

    if let Some(source) = object.get("source").and_then(Value::as_object) {
        if !source_media_type_is_image(source) {
            return None;
        }

        if let Some(url) = source
            .get("url")
            .and_then(Value::as_str)
            .filter(|url| !url.trim().is_empty())
        {
            let mut image_url = Map::new();
            image_url.insert("url".to_string(), Value::String(url.to_string()));
            merge_top_level_detail(part, &mut image_url);
            return Some(Value::Object(image_url));
        }

        if let Some(data) = source
            .get("data")
            .and_then(Value::as_str)
            .filter(|data| !data.is_empty())
        {
            let media_type = source
                .get("media_type")
                .or_else(|| source.get("mime_type"))
                .or_else(|| source.get("mimeType"))
                .and_then(Value::as_str)
                .unwrap_or("image/png");
            let url = if data
                .get(..11)
                .is_some_and(|prefix| prefix.eq_ignore_ascii_case("data:image/"))
            {
                data.to_string()
            } else {
                format!("data:{media_type};base64,{data}")
            };
            let mut image_url = Map::new();
            image_url.insert("url".to_string(), Value::String(url));
            merge_top_level_detail(part, &mut image_url);
            return Some(Value::Object(image_url));
        }
    }

    let data = object
        .get("data")
        .and_then(Value::as_str)
        .filter(|data| !data.is_empty())?;
    let media_type = object
        .get("mimeType")
        .or_else(|| object.get("mime_type"))
        .and_then(Value::as_str)
        .filter(|media_type| is_image_mime_type(media_type))?;
    let mut image_url = Map::new();
    image_url.insert(
        "url".to_string(),
        Value::String(format!("data:{media_type};base64,{data}")),
    );
    merge_top_level_detail(part, &mut image_url);
    Some(Value::Object(image_url))
}

fn image_url_content_part(image_url: Value) -> Value {
    let mut content_part = Map::new();
    content_part.insert("type".to_string(), Value::String("image_url".to_string()));
    content_part.insert("image_url".to_string(), image_url);
    Value::Object(content_part)
}

fn merge_top_level_detail(part: &Value, image_url: &mut Map<String, Value>) {
    if image_url.get("detail").is_none() {
        if let Some(detail) = part.get("detail") {
            image_url.insert("detail".to_string(), detail.clone());
        }
    }
}

fn source_media_type_is_image(source: &Map<String, Value>) -> bool {
    source
        .get("media_type")
        .or_else(|| source.get("mime_type"))
        .or_else(|| source.get("mimeType"))
        .and_then(Value::as_str)
        .is_none_or(is_image_mime_type)
}

fn is_image_mime_type(value: &str) -> bool {
    value
        .get(..6)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("image/"))
}

fn is_image_base64_data_url(value: &str) -> bool {
    let Some(comma_index) = value.find(',') else {
        return false;
    };
    let header = value[..comma_index].to_ascii_lowercase();
    header.starts_with("data:image/") && header.ends_with(";base64")
}

fn clamp_base64ish_strings(value: &mut Value) {
    match value {
        Value::String(text) => {
            let trimmed = text.trim();
            let should_omit = (trimmed.len() >= WHOLE_DATA_URL_MIN_BYTES
                && trimmed
                    .get(..5)
                    .is_some_and(|prefix| prefix.eq_ignore_ascii_case("data:")))
                || looks_like_base64_payload(trimmed);
            if should_omit {
                let byte_len = text.len();
                *text = format!("[cc-switch: omitted {byte_len} bytes]");
            }
        }
        Value::Array(items) => {
            for item in items {
                clamp_base64ish_strings(item);
            }
        }
        Value::Object(object) => {
            for nested in object.values_mut() {
                clamp_base64ish_strings(nested);
            }
        }
        _ => {}
    }
}

fn looks_like_base64_payload(value: &str) -> bool {
    if value.len() < BASE64ISH_MIN_BYTES {
        return false;
    }

    value
        .bytes()
        .all(|byte| matches!(byte, b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'+' | b'/' | b'='))
}

fn sanitize_anthropic_tool_use_input(name: &str, input: Value) -> Value {
    if name != "Read" {
        return input;
    }

    match input {
        Value::Object(mut object) => {
            if matches!(object.get("pages"), Some(Value::String(value)) if value.is_empty()) {
                object.remove("pages");
            }
            Value::Object(object)
        }
        other => other,
    }
}

fn canonical_json_string(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "null".to_string())
}

fn reasoning_summary_text(item: &Value) -> String {
    item.get("summary")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|part| {
            matches!(
                part.get("type").and_then(Value::as_str),
                Some("summary_text" | "reasoning_text")
            )
            .then(|| part.get("text").and_then(Value::as_str))
            .flatten()
        })
        .collect::<Vec<_>>()
        .join("")
}

fn encode_openai_reasoning_item(item: &Value) -> Option<String> {
    (item.get("type").and_then(Value::as_str) == Some("reasoning")).then_some(())?;
    let bytes = serde_json::to_vec(item).ok()?;
    Some(format!(
        "{OPENAI_REASONING_ITEM_PREFIX}{}",
        URL_SAFE_NO_PAD.encode(bytes)
    ))
}

fn decode_openai_reasoning_item(encoded: &str) -> Option<Value> {
    let payload = encoded.strip_prefix(OPENAI_REASONING_ITEM_PREFIX)?;
    let bytes = URL_SAFE_NO_PAD.decode(payload).ok()?;
    let item: Value = serde_json::from_slice(&bytes).ok()?;
    (item.get("type").and_then(Value::as_str) == Some("reasoning")).then_some(item)
}

fn anthropic_block_from_openai_reasoning_item(item: &Value) -> Option<Value> {
    (item.get("type").and_then(Value::as_str) == Some("reasoning")).then_some(())?;
    let text = reasoning_summary_text(item);
    let has_encrypted_content = item
        .get("encrypted_content")
        .and_then(Value::as_str)
        .is_some_and(|value| !value.is_empty());
    if has_encrypted_content {
        let envelope = encode_openai_reasoning_item(item)?;
        if text.is_empty() {
            return Some(json!({"type":"redacted_thinking", "data":envelope}));
        }
        return Some(json!({
            "type":"thinking", "thinking":text, "signature":envelope
        }));
    }
    (!text.is_empty()).then(|| json!({"type":"thinking", "thinking":text}))
}

fn openai_reasoning_item_from_anthropic_block(block: &Value) -> Option<Value> {
    match block.get("type").and_then(Value::as_str) {
        Some("thinking") => block
            .get("signature")
            .and_then(Value::as_str)
            .and_then(decode_openai_reasoning_item),
        Some("redacted_thinking") => block
            .get("data")
            .and_then(Value::as_str)
            .and_then(decode_openai_reasoning_item),
        _ => None,
    }
}

fn web_search_call_from_blocks(tool_use: &Value, tool_result: &Value) -> Value {
    let id = tool_use.get("id").and_then(Value::as_str).unwrap_or("");
    let input = tool_use.get("input").and_then(Value::as_object);
    let action_type = if input.is_some_and(|input| {
        input.get("pattern").and_then(Value::as_str).is_some()
            && input.get("url").and_then(Value::as_str).is_some()
    }) {
        "find_in_page"
    } else if input.is_some_and(|input| {
        input.get("url").and_then(Value::as_str).is_some()
            && !input.contains_key("query")
            && !input.contains_key("queries")
    }) {
        "open_page"
    } else {
        "search"
    };
    let mut action = Map::new();
    action.insert("type".to_string(), json!(action_type));
    if let Some(source) = input {
        let fields: &[&str] = match action_type {
            "find_in_page" => &["url", "pattern"],
            "open_page" => &["url"],
            _ => &["query", "queries"],
        };
        for field in fields {
            if let Some(value) = source.get(*field) {
                action.insert((*field).to_string(), value.clone());
            }
        }
    }
    if action_type == "search" {
        let mut seen = HashSet::new();
        let sources: Vec<Value> = tool_result
            .get("content")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|result| {
                let url = result
                    .get("url")
                    .and_then(Value::as_str)
                    .filter(|url| !url.is_empty())?;
                seen.insert(url.to_string())
                    .then(|| json!({"type":"url", "url":url}))
            })
            .collect();
        if !sources.is_empty() {
            action.insert("sources".to_string(), Value::Array(sources));
        }
    }
    let failed = tool_result.get("is_error").and_then(Value::as_bool) == Some(true)
        || tool_result
            .pointer("/content/type")
            .and_then(Value::as_str)
            .is_some_and(|kind| kind.ends_with("_error"));
    json!({
        "type":"web_search_call",
        "id":id,
        "status":if failed {"failed"} else {"completed"},
        "action":Value::Object(action)
    })
}

fn responses_to_anthropic(
    body: Value,
    tool_name: &str,
    max_uses: Option<u64>,
    client_model: &str,
) -> Result<Value, String> {
    validate_terminal_status(&body)?;
    let output = body
        .get("output")
        .and_then(Value::as_array)
        .ok_or_else(|| "Responses response has no output array".to_string())?;
    let search_indices: Vec<usize> = output
        .iter()
        .enumerate()
        .filter_map(|(index, item)| {
            (item.get("type").and_then(Value::as_str) == Some("web_search_call")).then_some(index)
        })
        .collect();
    let limit = max_uses.map(|value| usize::try_from(value).unwrap_or(usize::MAX));
    let retained: Vec<usize> = search_indices
        .iter()
        .copied()
        .take(limit.map_or(usize::MAX, |limit| limit.saturating_add(1)))
        .collect();
    let ordinal: HashMap<usize, usize> = retained
        .iter()
        .enumerate()
        .map(|(ordinal, index)| (*index, ordinal))
        .collect();
    let exceeded_index = limit.and_then(|limit| search_indices.get(limit).copied());

    let is_over_limit = |index: usize| {
        limit.is_some_and(|limit| ordinal.get(&index).is_some_and(|ordinal| *ordinal >= limit))
    };
    let result_error = |index: usize| {
        if is_over_limit(index) {
            Some(max_uses_error())
        } else {
            search_result_error(&output[index])
        }
    };

    let mut results_by_index = HashMap::new();
    for index in &retained {
        results_by_index.insert(
            *index,
            if result_error(*index).is_some() {
                Vec::new()
            } else {
                results_from_action(&output[*index])
            },
        );
    }
    let terminal_results = terminal_search_results(output, exceeded_index);
    for (index, results) in &mut results_by_index {
        if result_error(*index).is_none() {
            merge_result_metadata(results, &terminal_results);
        }
    }
    let attributed: HashSet<String> = results_by_index
        .values()
        .flatten()
        .filter_map(|result| {
            result
                .get("url")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .collect();
    let unassigned: Vec<Value> = terminal_results
        .into_iter()
        .filter(|result| {
            result
                .get("url")
                .and_then(Value::as_str)
                .is_some_and(|url| !attributed.contains(url))
        })
        .collect();
    if let Some(last_success) = retained
        .iter()
        .rev()
        .copied()
        .find(|index| result_error(*index).is_none())
    {
        let results = results_by_index.entry(last_success).or_default();
        let mut seen: HashSet<String> = results
            .iter()
            .filter_map(|result| {
                result
                    .get("url")
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .collect();
        for result in unassigned {
            if result
                .get("url")
                .and_then(Value::as_str)
                .is_some_and(|url| seen.insert(url.to_string()))
            {
                results.push(result);
            }
        }
    }

    let completed = body.get("status").and_then(Value::as_str) == Some("completed");
    let mut content = Vec::new();
    let mut has_function = false;
    let mut search_count = 0_u64;
    for (index, item) in output.iter().enumerate() {
        if exceeded_index.is_some_and(|boundary| index > boundary) {
            continue;
        }
        match item.get("type").and_then(Value::as_str).unwrap_or("") {
            "message" => {
                if let Some(parts) = item.get("content").and_then(Value::as_array) {
                    for part in parts {
                        match part.get("type").and_then(Value::as_str) {
                            Some("output_text") => {
                                if let Some(text) = output_text_with_url_citations(part) {
                                    content.push(json!({"type":"text", "text":text}));
                                }
                            }
                            Some("refusal") => {
                                if let Some(text) = part
                                    .get("refusal")
                                    .and_then(Value::as_str)
                                    .filter(|text| !text.is_empty())
                                {
                                    content.push(json!({"type":"text", "text":text}));
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            "function_call" => {
                let name = item.get("name").and_then(Value::as_str).unwrap_or("");
                let raw = item
                    .get("arguments")
                    .and_then(Value::as_str)
                    .unwrap_or("{}");
                let arguments = if raw.trim().is_empty() {
                    json!({})
                } else {
                    match serde_json::from_str::<Value>(raw) {
                        Ok(value) if value.is_object() => value,
                        Ok(_) | Err(_) if !completed => json!({}),
                        Ok(_) => {
                            return Err(
                                "Responses function_call arguments must be an object".to_string()
                            )
                        }
                        Err(error) => {
                            return Err(format!(
                                "invalid Responses function_call arguments: {error}"
                            ))
                        }
                    }
                };
                let arguments = sanitize_anthropic_tool_use_input(name, arguments);
                content.push(json!({
                    "type":"tool_use",
                    "id":item.get("call_id").or_else(|| item.get("id")).cloned().unwrap_or_else(|| json!("")),
                    "name":name,
                    "input":arguments
                }));
                has_function = true;
            }
            "web_search_call" if ordinal.contains_key(&index) => {
                let over_limit = is_over_limit(index);
                if !over_limit {
                    search_count += 1;
                }
                let id = item
                    .get("id")
                    .and_then(Value::as_str)
                    .filter(|id| !id.is_empty())
                    .map(str::to_string)
                    .unwrap_or_else(|| format!("ws_{index}"));
                content.push(json!({
                    "type":"server_tool_use",
                    "id":id,
                    "name":tool_name,
                    "input":search_action_input(item),
                    "caller":{"type":"direct"}
                }));
                let result_content = if over_limit {
                    max_uses_error()
                } else {
                    search_result_error(item).unwrap_or_else(|| {
                        Value::Array(results_by_index.remove(&index).unwrap_or_default())
                    })
                };
                content.push(json!({
                    "type":"web_search_tool_result",
                    "tool_use_id":id,
                    "content":result_content,
                    "caller":{"type":"direct"}
                }));
            }
            "reasoning" => {
                if let Some(block) = anthropic_block_from_openai_reasoning_item(item) {
                    content.push(block);
                }
            }
            _ => {}
        }
    }

    let mut usage = anthropic_usage(body.get("usage"));
    if search_count > 0 {
        usage["server_tool_use"] = json!({"web_search_requests":search_count});
    }
    let stop_reason = match body.get("status").and_then(Value::as_str) {
        Some("incomplete") => match body
            .pointer("/incomplete_details/reason")
            .and_then(Value::as_str)
        {
            Some("content_filter") => "end_turn",
            _ => "max_tokens",
        },
        _ if has_function => "tool_use",
        _ => "end_turn",
    };
    Ok(json!({
        "id":body.get("id").cloned().unwrap_or_else(|| json!("")),
        "type":"message",
        "role":"assistant",
        "content":content,
        "model":if client_model.is_empty() {
            body.get("model").cloned().unwrap_or_else(|| json!(""))
        } else {
            json!(client_model)
        },
        "stop_reason":stop_reason,
        "stop_sequence":Value::Null,
        "usage":usage
    }))
}

fn validate_terminal_status(body: &Value) -> Result<(), String> {
    let status = body.get("status").and_then(Value::as_str);
    let has_error = body.get("error").is_some_and(|error| !error.is_null());
    match status {
        Some("failed") | Some("cancelled") => Err(body
            .pointer("/error/message")
            .and_then(Value::as_str)
            .unwrap_or("Responses upstream failed")
            .to_string()),
        _ if has_error => Err(body
            .pointer("/error/message")
            .and_then(Value::as_str)
            .unwrap_or("Responses upstream returned an error envelope")
            .to_string()),
        _ => Ok(()),
    }
}

fn search_action_input(item: &Value) -> Value {
    let Some(action) = item.get("action").and_then(Value::as_object) else {
        return json!({});
    };
    let mut input = Map::new();
    for key in ["query", "queries", "url", "pattern"] {
        if let Some(value) = action.get(key) {
            input.insert(key.to_string(), value.clone());
        }
    }
    Value::Object(input)
}

fn results_from_action(item: &Value) -> Vec<Value> {
    let mut results = Vec::new();
    let mut seen = HashSet::new();
    for source in item
        .pointer("/action/sources")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(url) = source
            .get("url")
            .and_then(Value::as_str)
            .filter(|url| !url.is_empty())
        else {
            continue;
        };
        if !seen.insert(url.to_string()) {
            continue;
        }
        results.push(json!({
            "type":"web_search_result",
            "url":url,
            "title":source.get("title").and_then(Value::as_str).filter(|title| !title.is_empty()).unwrap_or(url),
            "encrypted_content":"",
            "page_age":source.get("page_age").filter(|value| value.is_string()).cloned().unwrap_or(Value::Null)
        }));
    }
    results
}

fn terminal_search_results(output: &[Value], boundary: Option<usize>) -> Vec<Value> {
    let mut results = Vec::new();
    let mut seen = HashSet::new();
    for (index, item) in output.iter().enumerate() {
        if boundary.is_some_and(|boundary| index > boundary) {
            continue;
        }
        let parts: &[Value] = if item.get("type").and_then(Value::as_str) == Some("message") {
            item.get("content")
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or_default()
        } else {
            std::slice::from_ref(item)
        };
        for part in parts {
            for annotation in part
                .get("annotations")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                if annotation.get("type").and_then(Value::as_str) != Some("url_citation") {
                    continue;
                }
                let Some(url) = annotation
                    .get("url")
                    .and_then(Value::as_str)
                    .filter(|url| !url.is_empty())
                else {
                    continue;
                };
                if seen.insert(url.to_string()) {
                    results.push(json!({
                        "type":"web_search_result",
                        "url":url,
                        "title":annotation.get("title").and_then(Value::as_str).filter(|title| !title.is_empty()).unwrap_or(url),
                        "encrypted_content":"",
                        "page_age":Value::Null
                    }));
                }
            }
        }
    }
    results
}

fn merge_result_metadata(target: &mut [Value], candidates: &[Value]) {
    for candidate in candidates {
        let Some(url) = candidate.get("url").and_then(Value::as_str) else {
            continue;
        };
        let Some(existing) = target
            .iter_mut()
            .find(|result| result.get("url").and_then(Value::as_str) == Some(url))
        else {
            continue;
        };
        if let Some(object) = existing.as_object_mut() {
            if object
                .get("title")
                .and_then(Value::as_str)
                .is_none_or(|title| title.is_empty() || title == url)
            {
                if let Some(title) = candidate.get("title").and_then(Value::as_str) {
                    object.insert("title".to_string(), json!(title));
                }
            }
        }
    }
}

fn search_result_error(item: &Value) -> Option<Value> {
    let status = item.get("status").and_then(Value::as_str);
    let has_error = item.get("error").is_some_and(|error| !error.is_null());
    if status.is_none_or(|status| status == "completed") && !has_error {
        return None;
    }
    let signal = [
        item.pointer("/error/code").and_then(Value::as_str),
        item.pointer("/error/type").and_then(Value::as_str),
        item.pointer("/error/message").and_then(Value::as_str),
        item.get("error").and_then(Value::as_str),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join(" ")
    .to_ascii_lowercase();
    let code = if signal.contains("max_uses") {
        "max_uses_exceeded"
    } else if signal.contains("too_many_requests")
        || signal.contains("rate_limit")
        || signal.contains("rate limit")
    {
        "too_many_requests"
    } else if signal.contains("query_too_long") || signal.contains("query too long") {
        "query_too_long"
    } else if signal.contains("request_too_large") || signal.contains("request too large") {
        "request_too_large"
    } else if signal.contains("invalid") {
        "invalid_tool_input"
    } else {
        "unavailable"
    };
    Some(json!({"type":"web_search_tool_result_error", "error_code":code}))
}

fn max_uses_error() -> Value {
    json!({"type":"web_search_tool_result_error", "error_code":"max_uses_exceeded"})
}

fn anthropic_usage(usage: Option<&Value>) -> Value {
    let usage = match usage {
        Some(value) if value.is_object() => value,
        _ => return json!({"input_tokens":0, "output_tokens":0}),
    };
    let input = usage
        .get("input_tokens")
        .or_else(|| usage.get("prompt_tokens"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let output = usage
        .get("output_tokens")
        .or_else(|| usage.get("completion_tokens"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let mut result = json!({
        "input_tokens":input,
        "output_tokens":output
    });

    if let Some(cached) = usage
        .pointer("/input_tokens_details/cached_tokens")
        .and_then(Value::as_u64)
    {
        result["cache_read_input_tokens"] = json!(cached);
    }
    if result.get("cache_read_input_tokens").is_none() {
        if let Some(cached) = usage
            .pointer("/prompt_tokens_details/cached_tokens")
            .and_then(Value::as_u64)
        {
            result["cache_read_input_tokens"] = json!(cached);
        }
    }
    if let Some(cache_write) = usage
        .pointer("/input_tokens_details/cache_write_tokens")
        .and_then(Value::as_u64)
        .or_else(|| {
            usage
                .pointer("/prompt_tokens_details/cache_write_tokens")
                .and_then(Value::as_u64)
        })
    {
        result["cache_creation_input_tokens"] = json!(cache_write);
    }

    if let Some(value) = usage.get("cache_read_input_tokens") {
        result["cache_read_input_tokens"] = value.clone();
    }
    if let Some(value) = usage.get("cache_creation_input_tokens") {
        result["cache_creation_input_tokens"] = value.clone();
    }
    if let Some(value) = usage.get("cache_creation") {
        result["cache_creation"] = value.clone();
    }

    let cached = result
        .get("cache_read_input_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let cache_creation = result
        .get("cache_creation_input_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    if cached > 0 || cache_creation > 0 {
        result["input_tokens"] = json!(input.saturating_sub(cached).saturating_sub(cache_creation));
    }
    result
}

fn has_http_url_scheme(value: &str) -> bool {
    value
        .get(.."http://".len())
        .is_some_and(|scheme| scheme.eq_ignore_ascii_case("http://"))
        || value
            .get(.."https://".len())
            .is_some_and(|scheme| scheme.eq_ignore_ascii_case("https://"))
}

/// Recover the terminal Responses payload from SSE returned by a backend that ignored
/// `stream: false`. Hosted server tools must be reconstructed from the terminal output;
/// accepting a partial stream would silently drop result pairing, citations, or usage.
pub fn terminal_response_from_sse(body: &[u8]) -> Result<Value, String> {
    let text = std::str::from_utf8(body)
        .map_err(|error| format!("Responses SSE is not valid UTF-8: {error}"))?;
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut terminal = None;

    for event_block in normalized.split("\n\n") {
        let data = event_block
            .lines()
            .filter_map(|line| {
                line.strip_prefix("data:")
                    .map(|value| value.strip_prefix(' ').unwrap_or(value))
            })
            .collect::<Vec<_>>()
            .join("\n");
        if data.is_empty() || data.trim() == "[DONE]" {
            continue;
        }
        let event: Value = serde_json::from_str(&data)
            .map_err(|error| format!("Responses SSE event is not valid JSON: {error}"))?;
        match event.get("type").and_then(Value::as_str) {
            Some("response.completed" | "response.incomplete") => {
                let response = event
                    .get("response")
                    .filter(|response| response.is_object())
                    .cloned()
                    .ok_or_else(|| {
                        "Responses SSE terminal event has no response object".to_string()
                    })?;
                terminal = Some(response);
            }
            Some("response.failed" | "error") => {
                let message = event
                    .pointer("/response/error/message")
                    .or_else(|| event.pointer("/error/message"))
                    .or_else(|| event.get("message"))
                    .and_then(Value::as_str)
                    .unwrap_or("Responses SSE reported a terminal error");
                return Err(message.to_string());
            }
            _ => {}
        }
    }

    terminal.ok_or_else(|| {
        "Responses SSE ended without a completed or incomplete terminal response".to_string()
    })
}

pub fn encode_anthropic_sse(message: &Value) -> String {
    let event = |name: &str, data: Value| {
        format!(
            "event: {name}\ndata: {}\n\n",
            serde_json::to_string(&data).unwrap_or_default()
        )
    };
    let usage = message.get("usage").cloned().unwrap_or_else(|| json!({}));
    let mut start_usage = usage.clone();
    start_usage["output_tokens"] = json!(0);
    let mut output = event(
        "message_start",
        json!({"type":"message_start", "message":{
            "id":message.get("id").cloned().unwrap_or_else(|| json!("")),
            "type":"message", "role":"assistant",
            "model":message.get("model").cloned().unwrap_or_else(|| json!("")),
            "content":[], "stop_reason":Value::Null, "stop_sequence":Value::Null,
            "usage":start_usage
        }}),
    );
    for (index, block) in message
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
    {
        match block.get("type").and_then(Value::as_str).unwrap_or("") {
            "text" => {
                output.push_str(&event("content_block_start", json!({"type":"content_block_start","index":index,"content_block":{"type":"text","text":""}})));
                if let Some(text) = block
                    .get("text")
                    .and_then(Value::as_str)
                    .filter(|text| !text.is_empty())
                {
                    output.push_str(&event("content_block_delta", json!({"type":"content_block_delta","index":index,"delta":{"type":"text_delta","text":text}})));
                }
                output.push_str(&event(
                    "content_block_stop",
                    json!({"type":"content_block_stop","index":index}),
                ));
            }
            "tool_use" | "server_tool_use" => {
                let kind = block
                    .get("type")
                    .and_then(Value::as_str)
                    .unwrap_or("tool_use");
                let mut start = json!({
                    "type":kind,
                    "id":block.get("id").cloned().unwrap_or_else(|| json!("")),
                    "name":block.get("name").cloned().unwrap_or_else(|| json!("")),
                    "input":{}
                });
                if kind == "server_tool_use" {
                    start["caller"] = json!({"type":"direct"});
                }
                output.push_str(&event(
                    "content_block_start",
                    json!({"type":"content_block_start","index":index,"content_block":start}),
                ));
                let input = block.get("input").cloned().unwrap_or_else(|| json!({}));
                output.push_str(&event("content_block_delta", json!({
                    "type":"content_block_delta","index":index,
                    "delta":{"type":"input_json_delta","partial_json":serde_json::to_string(&input).unwrap_or_else(|_| "{}".to_string())}
                })));
                output.push_str(&event(
                    "content_block_stop",
                    json!({"type":"content_block_stop","index":index}),
                ));
            }
            "web_search_tool_result" => {
                output.push_str(&event(
                    "content_block_start",
                    json!({"type":"content_block_start","index":index,"content_block":block}),
                ));
                output.push_str(&event(
                    "content_block_stop",
                    json!({"type":"content_block_stop","index":index}),
                ));
            }
            _ => {}
        }
    }
    output.push_str(&event(
        "message_delta",
        json!({
            "type":"message_delta",
            "delta":{"stop_reason":message.get("stop_reason").cloned().unwrap_or(Value::Null),"stop_sequence":Value::Null},
            "usage":usage
        }),
    ));
    output.push_str(&event("message_stop", json!({"type":"message_stop"})));
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_versions_and_maps_request_options() {
        let request = json!({
            "messages":[{"role":"user","content":"search"}],
            "tools":[{
                "type":"web_search_20260318", "name":"web_search_next",
                "allowed_callers":["direct"], "max_uses":3,
                "allowed_domains":["rust-lang.org"],
                "user_location":{"type":"approximate","country":"SG"}
            }],
            "tool_choice":{"type":"tool","name":"web_search_next"}
        });
        let bridge = HostedWebSearchBridge::from_anthropic_request(&request)
            .unwrap()
            .unwrap();
        let mut encoded = json!({"input":[],"tools":[]});
        bridge
            .apply_to_responses_request(&request, &mut encoded)
            .unwrap();
        assert_eq!(encoded["tools"][0]["type"], "web_search");
        assert_eq!(
            encoded["tools"][0]["filters"]["allowed_domains"][0],
            "rust-lang.org"
        );
        assert_eq!(encoded["max_tool_calls"], 3);
        assert_eq!(encoded["tool_choice"], json!({"type":"web_search"}));
        assert_eq!(encoded["include"], json!([SOURCES_INCLUDE]));
    }

    #[test]
    fn rejects_non_direct_or_unrepresentable_tools() {
        for tool in [
            json!({"type":"web_search_20260318","name":"web_search"}),
            json!({"type":"web_search_20250305","name":"web_search","allowed_callers":["code_execution_20260120"]}),
            json!({"type":"web_search_20250305","name":"web_search","blocked_domains":["example.com"]}),
            json!({"type":"web_search_20250305","name":"web_search","max_uses":0}),
            json!({"type":"web_search_20991231","name":"web_search"}),
        ] {
            let request = json!({"tools":[tool]});
            assert!(HostedWebSearchBridge::from_anthropic_request(&request).is_err());
        }
    }

    #[test]
    fn replays_paired_search_history_in_order() {
        let request = json!({
            "messages":[{
                "role":"assistant",
                "content":[
                    {"type":"server_tool_use","id":"ws_1","name":"web_search_next","input":{"query":"Rust"}},
                    {"type":"web_search_tool_result","tool_use_id":"ws_1","content":[
                        {"type":"web_search_result","url":"https://rust-lang.org","title":"Rust"}
                    ]},
                    {"type":"text","text":"Found it"}
                ]
            }],
            "tools":[{"type":"web_search_20260318","name":"web_search_next","allowed_callers":["direct"]}]
        });
        let bridge = HostedWebSearchBridge::from_anthropic_request(&request)
            .unwrap()
            .unwrap();
        let mut encoded = json!({"input":[],"tools":[]});
        bridge
            .apply_to_responses_request(&request, &mut encoded)
            .unwrap();
        assert_eq!(encoded["input"][0]["type"], "web_search_call");
        assert_eq!(
            encoded["input"][0]["action"]["sources"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(encoded["input"][1]["content"][0]["text"], "Found it");
    }

    #[test]
    fn restores_pairs_citations_usage_and_enforces_max_uses() {
        let request = json!({
            "tools":[{"type":"web_search_20250305","name":"web_search","max_uses":1}]
        });
        let bridge = HostedWebSearchBridge::from_anthropic_request(&request)
            .unwrap()
            .unwrap();
        let response = json!({
            "id":"resp_1", "status":"completed", "model":"gpt-5",
            "output":[
                {"type":"web_search_call","id":"ws_ok","status":"completed","action":{
                    "type":"search","query":"Rust","sources":[{"type":"url","url":"https://rust-lang.org"}]
                }},
                {"type":"web_search_call","id":"ws_extra","status":"completed","action":{"type":"search","query":"Cargo"}},
                {"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}
            ],
            "usage":{"input_tokens":10,"output_tokens":4}
        });
        let result = bridge
            .responses_to_anthropic(response, "claude-opus")
            .unwrap();
        let content = result["content"].as_array().unwrap();
        assert_eq!(content.len(), 4);
        assert_eq!(content[0]["type"], "server_tool_use");
        assert_eq!(content[1]["type"], "web_search_tool_result");
        assert_eq!(content[2]["id"], "ws_extra");
        assert_eq!(content[3]["content"]["error_code"], "max_uses_exceeded");
        assert_eq!(result["usage"]["server_tool_use"]["web_search_requests"], 1);
        assert!(encode_anthropic_sse(&result).contains("web_search_tool_result"));
    }

    #[test]
    fn request_bridge_preserves_documents_reasoning_and_rich_error_tool_results() {
        let reasoning = json!({
            "id":"rs_1", "type":"reasoning",
            "summary":[{"type":"summary_text","text":"Use the search tool."}],
            "encrypted_content":"opaque"
        });
        let thinking = anthropic_block_from_openai_reasoning_item(&reasoning).unwrap();
        let request = json!({
            "messages":[
                {"role":"user","content":[{
                    "type":"document", "title":"guide.pdf",
                    "source":{"type":"url","url":"https://example.com/guide.pdf"}
                }]},
                {"role":"assistant","content":[
                    thinking,
                    {"type":"tool_use","id":"call_1","name":"inspect","input":{"path":"/tmp"}}
                ]},
                {"role":"user","content":[{
                    "type":"tool_result", "tool_use_id":"call_1", "is_error":true,
                    "content":[
                        {"type":"text","text":"failed"},
                        {"type":"image","source":{"type":"url","url":"https://example.com/error.png"}},
                        {"type":"document","filename":"error.pdf","source":{
                            "type":"base64","media_type":"application/pdf","data":"ZGF0YQ=="
                        }}
                    ]
                }]}
            ],
            "tools":[{"type":"web_search_20250305","name":"web_search"}]
        });
        let bridge = HostedWebSearchBridge::from_anthropic_request(&request)
            .unwrap()
            .unwrap();
        let mut encoded = json!({"input":[],"tools":[]});
        bridge
            .apply_to_responses_request(&request, &mut encoded)
            .unwrap();
        let input = encoded["input"].as_array().unwrap();

        assert_eq!(input[0]["content"][0]["type"], "input_file");
        assert_eq!(input[1], reasoning);
        assert_eq!(input[2]["type"], "function_call");
        let output = input[3]["output"].as_array().unwrap();
        assert_eq!(output[0]["text"], TOOL_RESULT_ERROR_MARKER);
        assert_eq!(output[1]["text"], "failed");
        assert_eq!(output[2]["type"], "input_image");
        assert_eq!(output[3]["type"], "input_file");
    }

    #[test]
    fn response_reasoning_round_trips_and_citation_labels_are_markdown_safe() {
        let request = json!({
            "tools":[{"type":"web_search_20250305","name":"web_search"}]
        });
        let bridge = HostedWebSearchBridge::from_anthropic_request(&request)
            .unwrap()
            .unwrap();
        let reasoning = json!({
            "id":"rs_1", "type":"reasoning",
            "summary":[{"type":"summary_text","text":"Search first."}],
            "encrypted_content":"opaque"
        });
        let response = json!({
            "id":"resp_1", "status":"completed", "model":"gpt-5.6",
            "output":[
                reasoning,
                {"type":"web_search_call","id":"ws_1","status":"completed","action":{
                    "type":"search","query":"Rust","sources":[{
                        "type":"url","url":"https://doc.rust-lang.org/"
                    }]
                }},
                {"type":"message","role":"assistant","content":[{
                    "type":"output_text","text":"answer","annotations":[{
                        "type":"url_citation","url":"https://doc.rust-lang.org/",
                        "title":"](https://evil.example) [Rust]"
                    }]
                }]}
            ],
            "usage":{"input_tokens":3,"output_tokens":2}
        });
        let anthropic = bridge
            .responses_to_anthropic(response, "claude-opus")
            .unwrap();
        let content = anthropic["content"].as_array().unwrap();
        assert_eq!(content[0]["type"], "thinking");
        assert!(content[0]["signature"]
            .as_str()
            .unwrap()
            .starts_with(OPENAI_REASONING_ITEM_PREFIX));
        let rendered = content
            .iter()
            .find(|block| block.get("type").and_then(Value::as_str) == Some("text"))
            .unwrap()["text"]
            .as_str()
            .unwrap();
        assert!(rendered.contains(r"\]\(https\:\/\/evil\.example\)"));
        assert!(!rendered.contains("](https://evil.example)"));

        let replay = json!({
            "messages":[{"role":"assistant","content":content}],
            "tools":[{"type":"web_search_20250305","name":"web_search"}]
        });
        let replay_bridge = HostedWebSearchBridge::from_anthropic_request(&replay)
            .unwrap()
            .unwrap();
        let mut encoded = json!({"input":[],"tools":[]});
        replay_bridge
            .apply_to_responses_request(&replay, &mut encoded)
            .unwrap();
        assert_eq!(encoded["input"][0], reasoning);
    }

    #[test]
    fn extracts_large_whole_data_url_from_tool_result() {
        let data_url = format!(
            "data:image/png;base64,{}",
            "A".repeat(WHOLE_DATA_URL_MIN_BYTES)
        );
        let output = anthropic_tool_result_output(&json!({
            "type":"tool_result",
            "tool_use_id":"call_1",
            "content":data_url
        }));
        let parts = output.as_array().unwrap();

        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0]["type"], "input_text");
        assert_eq!(parts[0]["text"], TOOL_RESULT_MEDIA_ATTACHED_MARKER);
        assert_eq!(parts[1]["type"], "input_image");
        assert_eq!(parts[1]["image_url"], data_url);
    }

    #[test]
    fn extracts_json_embedded_tool_image_and_clamps_residual_payloads() {
        let data_url = format!(
            "data:image/png;base64,{}",
            "A".repeat(WHOLE_DATA_URL_MIN_BYTES)
        );
        let residual = "B".repeat(BASE64ISH_MIN_BYTES);
        let embedded = canonical_json_string(&json!({
            "content":[
                {"type":"input_image","image_url":data_url,"detail":"high"},
                {"blob":residual}
            ]
        }));
        let output = anthropic_tool_result_output(&json!({
            "type":"tool_result",
            "tool_use_id":"call_1",
            "content":embedded
        }));
        let parts = output.as_array().unwrap();

        assert_eq!(parts.len(), 2);
        let sanitized = parts[0]["text"].as_str().unwrap();
        assert!(sanitized.contains(TOOL_RESULT_MEDIA_ATTACHED_MARKER));
        assert!(sanitized.contains("[cc-switch: omitted 16384 bytes]"));
        assert!(!sanitized.contains(&residual));
        assert_eq!(parts[1]["type"], "input_image");
        assert_eq!(parts[1]["image_url"], data_url);
        assert_eq!(parts[1]["detail"], "high");
    }

    #[test]
    fn sanitizes_read_pages_and_accepts_blank_completed_arguments() {
        let request = json!({
            "tools":[{"type":"web_search_20250305","name":"web_search"}]
        });
        let bridge = HostedWebSearchBridge::from_anthropic_request(&request)
            .unwrap()
            .unwrap();
        let response = json!({
            "id":"resp_1", "status":"completed", "model":"gpt-5",
            "output":[
                {"type":"function_call","call_id":"call_1","name":"Read",
                 "arguments":"{\"file_path\":\"/tmp/demo.py\",\"pages\":\"\"}"},
                {"type":"function_call","call_id":"call_2","name":"noop","arguments":"  \n\t"}
            ],
            "usage":{"input_tokens":1,"output_tokens":1}
        });
        let result = bridge
            .responses_to_anthropic(response, "claude-opus")
            .unwrap();
        let content = result["content"].as_array().unwrap();

        assert_eq!(content[0]["input"]["file_path"], "/tmp/demo.py");
        assert!(content[0]["input"].get("pages").is_none());
        assert_eq!(content[1]["input"], json!({}));
    }

    #[test]
    fn preserves_cache_usage_details_with_cc_switch_precedence() {
        let usage = json!({
            "input_tokens":100,
            "output_tokens":7,
            "input_tokens_details":{"cached_tokens":80,"cache_write_tokens":10},
            "cache_read_input_tokens":60,
            "cache_creation_input_tokens":20,
            "cache_creation":{"ephemeral_5m_input_tokens":12,"ephemeral_1h_input_tokens":8}
        });
        let result = anthropic_usage(Some(&usage));

        assert_eq!(result["input_tokens"], 20);
        assert_eq!(result["output_tokens"], 7);
        assert_eq!(result["cache_read_input_tokens"], 60);
        assert_eq!(result["cache_creation_input_tokens"], 20);
        assert_eq!(result["cache_creation"], usage["cache_creation"]);

        let clamped = anthropic_usage(Some(&json!({
            "input_tokens":100,
            "output_tokens":1,
            "cache_read_input_tokens":60,
            "cache_creation_input_tokens":50
        })));
        assert_eq!(clamped["input_tokens"], 0);
    }

    #[test]
    fn extracts_terminal_response_from_crlf_sse_and_rejects_truncation() {
        let body = concat!(
            ": keep-alive\r\n\r\n",
            "event: response.created\r\n",
            "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\r\n\r\n",
            "event: response.completed\r\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"output\":[]}}\r\n\r\n",
            "data: [DONE]\r\n\r\n"
        );
        let response = terminal_response_from_sse(body.as_bytes()).unwrap();
        assert_eq!(response["id"], "resp_1");

        let truncated = b"data: {\"type\":\"response.created\"}\n\n";
        assert!(terminal_response_from_sse(truncated)
            .unwrap_err()
            .contains("without a completed or incomplete terminal response"));
    }
}
