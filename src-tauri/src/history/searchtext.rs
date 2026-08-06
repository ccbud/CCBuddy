// ---- content search (the session list's "big search") ----
//
// Scans session CONTENT (message text / thinking / tool calls + results) across every listed
// session — main threads, their subagent transcripts, and Codex rollouts — and reports, per
// matching session, WHERE the first match lives ("main" or a subagent's tool_use key) plus a
// display snippet. The renderer opens the session, switches the panel to that agent, and
// re-finds the query locally, so list hits and in-conversation positioning stay aligned.
//
// Performance model (this runs per keystroke, debounced):
//  - extraction cache: path -> (mtime, size, extracted text), so repeated queries pay the JSON
//    parse + shaping once per file version;
//  - raw prefilter: on a cache miss the raw JSONL bytes are substring-scanned first, and only
//    files that could match are parsed at all (JSON escapes quotes/backslashes/control chars,
//    so the prefilter is skipped for queries containing those);
//  - parallel scan: per-file work fans out over a small thread pool.

use serde_json::Value;

use super::searchfmt::strip_injected;

/// ASCII-case-insensitive substring search (byte-wise; non-ASCII must match exactly — CJK has no
/// case). A valid-UTF-8 needle can only match at char boundaries of valid-UTF-8 text (ASCII bytes
/// never equal continuation bytes), so the returned byte offset is safe to slice on.
pub(super) fn ifind(hay: &str, needle: &str, from: usize) -> Option<usize> {
    let h = hay.as_bytes();
    let n = needle.as_bytes();
    if n.is_empty() || h.len() < n.len() {
        return None;
    }
    let last = h.len() - n.len();
    let n0 = n[0].to_ascii_lowercase();
    let mut i = from;
    while i <= last {
        if h[i].to_ascii_lowercase() == n0 {
            let mut k = 1;
            while k < n.len() && h[i + k].to_ascii_lowercase() == n[k].to_ascii_lowercase() {
                k += 1;
            }
            if k == n.len() {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

/// Non-overlapping case-insensitive occurrence count (same fold as ifind).
pub(super) fn icount(hay: &str, needle: &str) -> usize {
    let (mut i, mut c) = (0usize, 0usize);
    while let Some(p) = ifind(hay, needle, i) {
        c += 1;
        i = p + needle.len().max(1);
    }
    c
}

fn tool_result_search_text(c: &Value) -> String {
    if let Some(s) = c.as_str() {
        return s.to_string();
    }
    if let Some(arr) = c.as_array() {
        return arr
            .iter()
            .filter_map(|x| x.get("text").and_then(|t| t.as_str()))
            .collect::<Vec<_>>()
            .join("\n");
    }
    String::new()
}

/// One searchable text blob for a shaped message list — the renderer's messagePlainText, flattened:
/// user prose (injected blocks stripped), assistant text, thinking, tool name + input JSON, and
/// tool results. Images and raw structure are skipped so a hit here is findable in the panel.
pub(super) fn extract_search_text(messages: &[Value]) -> String {
    let mut out = String::new();
    let mut push = |t: &str| {
        if !t.is_empty() {
            out.push_str(t);
            out.push('\n');
        }
    };
    for m in messages {
        let role = m.get("role").and_then(|v| v.as_str()).unwrap_or("");
        let content = match m.get("content") {
            Some(c) => c,
            None => continue,
        };
        if let Some(s) = content.as_str() {
            if role == "user" {
                push(&strip_injected(s));
            } else {
                push(s);
            }
            continue;
        }
        let arr = match content.as_array() {
            Some(a) => a,
            None => continue,
        };
        for b in arr {
            match b.get("type").and_then(|v| v.as_str()).unwrap_or("") {
                "text" => {
                    let t = b.get("text").and_then(|v| v.as_str()).unwrap_or("");
                    if role == "user" {
                        push(&strip_injected(t));
                    } else {
                        push(t);
                    }
                }
                "thinking" => push(b.get("thinking").and_then(|v| v.as_str()).unwrap_or("")),
                "skill_load" => {
                    push(b.get("name").and_then(Value::as_str).unwrap_or(""));
                    push(b.get("path").and_then(Value::as_str).unwrap_or(""));
                    push(b.get("snapshot").and_then(Value::as_str).unwrap_or(""));
                }
                "tool_use" => {
                    let name = b.get("name").and_then(|v| v.as_str()).unwrap_or("");
                    let input = b.get("input").map(|i| i.to_string()).unwrap_or_default();
                    push(&format!("{} {}", name, input));
                }
                "tool_result" => {
                    push(&tool_result_search_text(b.get("content").unwrap_or(&Value::Null)))
                }
                _ => {}
            }
        }
    }
    out
}
