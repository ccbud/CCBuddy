// Reading the content of Responses items: text / image parts, reasoning summaries, and call ids.

use llm_connector::types::{Message, MessageBlock};
use serde_json::Value;

// ---------------------------------------------------------------------------
// client-side half: a Responses client (Codex) in front of the gateway
// ---------------------------------------------------------------------------

/// Pull text out of a Responses content value (string, or array of typed parts). Accepts the
/// input_text / output_text / text / summary_text part flavors.
pub(super) fn parts_text(content: &Value) -> String {
    if let Some(s) = content.as_str() {
        return s.to_string();
    }
    let arr = match content.as_array() {
        Some(a) => a,
        None => return String::new(),
    };
    let mut out: Vec<String> = vec![];
    for p in arr {
        match p.get("type").and_then(|t| t.as_str()) {
            Some("input_text") | Some("output_text") | Some("text") | Some("summary_text") => {
                if let Some(t) = p.get("text").and_then(|v| v.as_str()) {
                    out.push(t.to_string());
                }
            }
            _ => {}
        }
    }
    out.join("\n")
}

/// input_image parts → IR image blocks. Codex sends `image_url` as a data URI (screenshots /
/// attached images); a plain URL is also accepted per the OpenAI spec.
pub(super) fn parts_images(content: &Value) -> Vec<MessageBlock> {
    let arr = match content.as_array() {
        Some(a) => a,
        None => return vec![],
    };
    let mut out = vec![];
    for p in arr {
        if p.get("type").and_then(|t| t.as_str()) != Some("input_image") {
            continue;
        }
        let url = p.get("image_url").and_then(|v| v.as_str()).or_else(|| {
            p.get("image_url")
                .and_then(|v| v.get("url"))
                .and_then(|v| v.as_str())
        });
        let Some(u) = url else { continue };
        if let Some(rest) = u.strip_prefix("data:") {
            if let Some((meta, data)) = rest.split_once(";base64,") {
                if !data.is_empty() {
                    out.push(MessageBlock::image_base64(
                        if meta.is_empty() { "image/png" } else { meta },
                        data,
                    ));
                }
                continue;
            }
        }
        out.push(MessageBlock::image_url(u));
    }
    out
}

/// Reasoning text carried by a Responses `reasoning` item: the summary parts (what a transcoded
/// stream emits and Codex echoes back), falling back to full `content` parts.
pub(super) fn reasoning_item_text(item: &Value) -> Option<String> {
    for key in ["summary", "content"] {
        let Some(parts) = item.get(key).and_then(|v| v.as_array()) else {
            continue;
        };
        let text = parts
            .iter()
            .filter_map(|p| {
                p.get("text")
                    .and_then(|v| v.as_str())
                    .or_else(|| p.as_str())
            })
            .filter(|t| !t.is_empty())
            .collect::<Vec<_>>()
            .join("\n\n");
        if !text.trim().is_empty() {
            return Some(text);
        }
    }
    None
}

/// Append reasoning text onto a message's `reasoning_content` (the OpenAI-chat wire field).
pub(super) fn append_reasoning_content(message: &mut Message, text: &str) {
    let text = text.trim();
    if text.is_empty() {
        return;
    }
    match &mut message.reasoning_content {
        // Transcoded Responses output deliberately carries the same reasoning both
        // as a sibling `reasoning` item and on each call item, so either surviving
        // history representation is sufficient. Do not multiply it when both (or
        // several parallel calls) are present.
        Some(existing) if existing.trim() == text => {}
        Some(existing) if !existing.is_empty() => {
            existing.push_str("\n\n");
            existing.push_str(text);
        }
        slot => *slot = Some(text.to_string()),
    }
}

pub(super) fn response_item_call_id(item: &Value) -> Option<&str> {
    item.get("call_id")
        .or_else(|| item.get("id"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
}
