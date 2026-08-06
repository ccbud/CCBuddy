// One `steps` row → renderer messages, plus the depth-first string probe the cwd fallback uses.
// Moved verbatim from antigravity.rs.

use crate::history::Norm;
use serde_json::{json, Value};

use super::content::{b64_encode, map_tool};
use super::wire::{
    field_bytes, field_msg, field_str, field_varint, ts_of, wire_fields, Wire,
};

/// Decode one step row into zero or more renderer messages, accumulating usage into `n`.
pub(super) fn push_step(n: &mut Norm, payload: &[u8]) {
    let fields = match wire_fields(payload) {
        Some(f) => f,
        None => return,
    };
    let meta5 = field_msg(&fields, 5).unwrap_or_default();
    let ts = ts_of(&meta5, 1);
    let with_ts = |mut m: Value| {
        if let Some(t) = &ts {
            m["ts"] = json!(t);
        }
        m
    };

    // user turn: #19 {2: text, 9: attachments {1 mime, 2 bytes, 5 path}}
    if let Some(user) = field_msg(&fields, 19) {
        let mut blocks: Vec<Value> = vec![];
        if let Some(text) = field_str(&user, 2) {
            if !text.trim().is_empty() {
                blocks.push(json!({ "type": "text", "text": text }));
            }
        }
        for (f, w) in &user {
            if *f != 9 {
                continue;
            }
            if let Wire::Bytes(b) = w {
                if let Some(att) = wire_fields(b) {
                    let mime = field_str(&att, 1).unwrap_or_default();
                    let data = field_bytes(&att, 2);
                    match data {
                        // cap embedded images at 8 MB raw — larger ones degrade to a path note
                        Some(bytes) if mime.starts_with("image/") && bytes.len() <= 8_000_000 => {
                            blocks.push(json!({
                                "type": "image",
                                "source": { "type": "base64", "media_type": mime, "data": b64_encode(bytes) }
                            }));
                        }
                        _ => {
                            if let Some(p) = field_str(&att, 5) {
                                blocks.push(json!({ "type": "text", "text": format!("[attachment: {}]", p) }));
                            }
                        }
                    }
                }
            }
        }
        if !blocks.is_empty() {
            n.messages.push(with_ts(json!({ "role": "user", "content": blocks })));
        }
        return;
    }

    // tool call: #5.4 {1 id, 2 name, 3 args-json} (results are stored opaquely — omitted)
    if let Some(call) = field_msg(&meta5, 4) {
        let name = field_str(&call, 2).unwrap_or_else(|| "tool".into());
        let args: Value = field_str(&call, 3)
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or(json!({}));
        let (tname, input) = map_tool(&name, &args);
        let id = field_str(&call, 1).unwrap_or_default();
        n.messages.push(with_ts(json!({
            "role": "assistant",
            "content": [{ "type": "tool_use", "id": id, "name": tname, "input": input }],
        })));
        return;
    }

    // model turn: #20.1 assistant text; #5.9 {2 input, 3 output} token stats
    let turn20 = field_msg(&fields, 20);
    let text = turn20.as_ref().and_then(|t| field_str(t, 1).or_else(|| field_str(t, 8)));
    let stats = field_msg(&meta5, 9);
    let usage = stats.as_ref().map(|st| {
        let input = field_varint(st, 2).unwrap_or(0) as i64;
        let output = field_varint(st, 3).unwrap_or(0) as i64;
        json!({ "inputTokens": input, "outputTokens": output, "cacheRead": 0, "cacheCreation": 0 })
    });
    if let Some(text) = text {
        if !text.trim().is_empty() {
            let mut m = json!({ "role": "assistant", "content": [{ "type": "text", "text": text }] });
            if let Some(u) = &usage {
                let input = u.get("inputTokens").and_then(|v| v.as_i64()).unwrap_or(0);
                let output = u.get("outputTokens").and_then(|v| v.as_i64()).unwrap_or(0);
                if input + output > 0 {
                    m["usage"] = u.clone();
                    let t = n.totals.as_object_mut().unwrap();
                    t["in"] = json!(t["in"].as_i64().unwrap_or(0) + input);
                    t["out"] = json!(t["out"].as_i64().unwrap_or(0) + output);
                    t["turns"] = json!(t["turns"].as_i64().unwrap_or(0) + 1);
                }
            }
            n.messages.push(with_ts(m));
        }
    }
}

/// Depth-first search for the first utf8 string field with `prefix` anywhere in a message tree.
pub(super) fn find_str_with_prefix(buf: &[u8], prefix: &str, depth: u8) -> Option<String> {
    let fields = wire_fields(buf)?;
    for (_, w) in &fields {
        if let Wire::Bytes(b) = w {
            if let Ok(s) = std::str::from_utf8(b) {
                if s.starts_with(prefix) {
                    return Some(s.to_string());
                }
            }
            if depth < 6 {
                if let Some(found) = find_str_with_prefix(b, prefix, depth + 1) {
                    return Some(found);
                }
            }
        }
    }
    None
}
