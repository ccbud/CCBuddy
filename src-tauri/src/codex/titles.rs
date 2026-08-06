// User-text joining and title extraction from rollout content (split from codex.rs).

use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;

use super::records::split_line;

pub(super) fn joined_text(content: &Value, kinds: &[&str]) -> String {
    let arr = match content.as_array() {
        Some(a) => a,
        None => return content.as_str().unwrap_or("").to_string(),
    };
    arr.iter()
        .filter(|b| kinds.contains(&b.get("type").and_then(|t| t.as_str()).unwrap_or("")))
        .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
        .collect::<Vec<_>>()
        .join("\n")
}

// Codex surrounds each real input_image with text-only transport tags. Replace the opening tag
// with its safe display name (`[Image #1]`) and drop the closing tag; image_block still carries
// the actual bitmap to the renderer.
fn image_transport_label(text: &str) -> Option<String> {
    let source = text.trim();
    let lower = source.to_ascii_lowercase();
    if !lower.starts_with("<image") || !source.ends_with('>') {
        return None;
    }
    let boundary = source.as_bytes().get(6).copied();
    if !matches!(boundary, Some(b'>')) && !boundary.map(|b| b.is_ascii_whitespace()).unwrap_or(false) {
        return None;
    }

    let mut label = None;
    if let Some(pos) = lower.find("name") {
        let rest = source[pos + 4..].trim_start();
        if let Some(value) = rest.strip_prefix('=') {
            let value = value.trim_start();
            label = if let Some(quote) = value.chars().next().filter(|c| *c == '"' || *c == '\'') {
                value[quote.len_utf8()..]
                    .find(quote)
                    .map(|end| value[quote.len_utf8()..quote.len_utf8() + end].to_string())
            } else if value.starts_with('[') {
                value.find(']').map(|end| value[..=end].to_string())
            } else {
                Some(value.split(|c: char| c.is_whitespace() || c == '>').next().unwrap_or("").to_string())
            };
        }
    }
    Some(label.filter(|s| !s.trim().is_empty()).unwrap_or_else(|| "[Image]".to_string()))
}

pub(super) fn joined_user_text(content: &Value) -> String {
    let arr = match content.as_array() {
        Some(a) => a,
        None => return content.as_str().unwrap_or("").to_string(),
    };
    let has_image = arr
        .iter()
        .any(|b| b.get("type").and_then(|t| t.as_str()) == Some("input_image"));
    arr.iter()
        .filter(|b| matches!(b.get("type").and_then(|t| t.as_str()), Some("input_text") | Some("text")))
        .filter_map(|b| {
            let text = b.get("text").and_then(|t| t.as_str()).unwrap_or("");
            if has_image {
                if text.trim().eq_ignore_ascii_case("</image>") {
                    return None;
                }
                if let Some(label) = image_transport_label(text) {
                    return Some(label);
                }
            }
            if text.is_empty() { None } else { Some(text.to_string()) }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn event_user_display_text(payload: &Value) -> String {
    let message = payload.get("message").and_then(|v| v.as_str()).unwrap_or("").trim();
    let image_count = payload.get("images").and_then(|v| v.as_array()).map(Vec::len).unwrap_or(0)
        + payload.get("local_images").and_then(|v| v.as_array()).map(Vec::len).unwrap_or(0);
    let labels = (1..=image_count)
        .map(|i| format!("[Image #{}]", i))
        .collect::<Vec<_>>()
        .join(" ");
    format!("{}{}{}", labels, if !labels.is_empty() && !message.is_empty() { " " } else { "" }, message)
        .trim()
        .to_string()
}

fn event_user_title_from_record(rec: &Value) -> String {
    let (ty, payload, _) = split_line(rec);
    if ty != "event_msg" || payload.get("type").and_then(|v| v.as_str()) != Some("user_message") {
        return String::new();
    }
    let text = event_user_display_text(payload);
    if text.is_empty() {
        String::new()
    } else {
        crate::history::first_user_text(&[json!({
            "role": "user",
            "content": [{ "type": "text", "text": text }],
        })])
    }
}

pub(super) fn first_event_user_title(recs: &[Value]) -> String {
    recs.iter()
        .map(event_user_title_from_record)
        .find(|title| !title.is_empty())
        .unwrap_or_default()
}

fn append_scan_segment(line: &mut Vec<u8>, dropping: &mut bool, segment: &[u8], max_line: usize) {
    if *dropping || segment.is_empty() {
        return;
    }
    if line.len().saturating_add(segment.len()) > max_line {
        line.clear();
        *dropping = true;
    } else {
        line.extend_from_slice(segment);
    }
}

fn event_user_title_from_line(line: &[u8]) -> String {
    let line = line.strip_suffix(b"\r").unwrap_or(line);
    serde_json::from_slice::<Value>(line)
        .map(|rec| event_user_title_from_record(&rec))
        .unwrap_or_default()
}

// List metadata normally parses only the first 128 KiB. If an image-first response_item is a
// larger single JSON line, stream past it and read the following compact user_message event.
pub(super) fn scan_event_user_title(file: &Path) -> String {
    const MAX_SCAN: usize = 64 * 1024 * 1024;
    const MAX_LINE: usize = 256 * 1024;
    let input = match fs::File::open(file) {
        Ok(file) => file,
        Err(_) => return String::new(),
    };
    let mut reader = BufReader::new(input);
    let mut line: Vec<u8> = vec![];
    let mut dropping = false;
    let mut scanned = 0usize;
    while scanned < MAX_SCAN {
        let available = match reader.fill_buf() {
            Ok(buf) if !buf.is_empty() => buf,
            Ok(_) | Err(_) => break,
        };
        let take = available.len().min(MAX_SCAN - scanned);
        let mut start = 0usize;
        for i in 0..take {
            if available[i] == b'\n' {
                append_scan_segment(&mut line, &mut dropping, &available[start..i], MAX_LINE);
                let title = if dropping { String::new() } else { event_user_title_from_line(&line) };
                line.clear();
                dropping = false;
                if !title.is_empty() {
                    return title;
                }
                start = i + 1;
            }
        }
        append_scan_segment(&mut line, &mut dropping, &available[start..take], MAX_LINE);
        reader.consume(take);
        scanned = scanned.saturating_add(take);
    }
    if dropping { String::new() } else { event_user_title_from_line(&line) }
}
