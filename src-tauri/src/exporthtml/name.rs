// The default export filename. Moved verbatim from exporthtml.rs.

use serde_json::Value;

use super::build::build_data;

// ---- export filename ----
// Default export base name: `<project>-<convStart>-<exportedAt>`, both timestamps as YYMMDDHHmm
// (local time). Earlier exports used collision-prone names (UUID-only JSONL or first-message HTML);
// this keeps bulk exports stable and sortable.

// path/url-hostile chars + whitespace runs collapse to a single `_`; leading/trailing `_ . -` are
// trimmed; result capped at 60 chars.
pub(super) fn sanitize_name(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut prev_underscore = false;
    for ch in s.chars() {
        let bad = matches!(
            ch,
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\n' | '\r'
        ) || ch.is_whitespace();
        if bad {
            if !prev_underscore {
                out.push('_');
                prev_underscore = true;
            }
        } else {
            out.push(ch);
            prev_underscore = false;
        }
    }
    out.trim_matches(|c| c == '_' || c == '.' || c == '-')
        .chars()
        .take(60)
        .collect()
}

// Parse an ISO-8601 `ts` and render it as YYMMDDHHmm in local time (matches `new Date(ts)` + the
// Date's local getters used by the original).
pub(super) fn fmt_ts_local(ts: &str) -> Option<String> {
    chrono::DateTime::parse_from_rfc3339(ts).ok().map(|dt| {
        dt.with_timezone(&chrono::Local)
            .format("%y%m%d%H%M")
            .to_string()
    })
}

// Derive the base name from already-built export `data` (avoids re-parsing for the HTML path).
pub fn export_base_name_from_data(data: &Value) -> String {
    let meta = data.get("meta");
    let project = meta
        .and_then(|m| m.get("project"))
        .and_then(|v| v.as_str())
        .map(sanitize_name)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "conversation".to_string());
    let conv_part = meta
        .and_then(|m| m.get("firstTs"))
        .and_then(|v| v.as_str())
        .and_then(fmt_ts_local)
        .unwrap_or_else(|| "unknown".to_string());
    let exported_at = chrono::Local::now().format("%y%m%d%H%M").to_string();
    format!("{}-{}-{}", project, conv_part, exported_at)
}

// Build + shape the file, then derive the base name (JSONL export path, which has no `data` yet).
pub fn export_base_name(file: &str) -> String {
    export_base_name_from_data(&build_data(file))
}
