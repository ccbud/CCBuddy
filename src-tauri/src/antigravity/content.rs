// Attachment base64 and the Antigravity tool → renderer tool mapping. Moved verbatim from
// antigravity.rs.

use serde_json::{json, Value};

// ---- content mapping ----

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub(super) fn b64_encode(data: &[u8]) -> String {
    let mut out = String::with_capacity((data.len() + 2) / 3 * 4);
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(B64[(n >> 18) as usize & 63] as char);
        out.push(B64[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { B64[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { B64[n as usize & 63] as char } else { '=' });
    }
    out
}

/// Antigravity tool name + parsed arguments → (renderer tool name, renderer input). The args
/// JSON carries display strings (toolAction/toolSummary) alongside the real params — dropped
/// from generic passthrough to keep cards clean.
pub(super) fn map_tool(name: &str, args: &Value) -> (String, Value) {
    let s = |k: &str| args.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
    match name {
        "run_command" => {
            let mut input = json!({ "command": s("CommandLine") });
            if !s("Cwd").is_empty() {
                input["description"] = json!(s("Cwd"));
            }
            ("Bash".into(), input)
        }
        "view_file" => ("Read".into(), json!({ "file_path": s("AbsolutePath") })),
        "list_dir" => ("LS".into(), json!({ "path": s("DirectoryPath") })),
        "grep_search" => {
            let mut input = json!({ "pattern": s("Query") });
            if !s("SearchPath").is_empty() {
                input["path"] = json!(s("SearchPath"));
            }
            ("Grep".into(), input)
        }
        "find_by_name" => ("Glob".into(), json!({ "pattern": s("Pattern"), "path": s("SearchDirectory") })),
        "replace_file_content" => (
            "Edit".into(),
            json!({ "file_path": s("TargetFile"), "old_string": s("TargetContent"), "new_string": s("ReplacementContent") }),
        ),
        "write_to_file" => (
            "Write".into(),
            json!({ "file_path": s("TargetFile"), "content": s("CodeContent") }),
        ),
        "read_url_content" => ("WebFetch".into(), json!({ "url": s("Url") })),
        "search_web" => ("WebSearch".into(), json!({ "query": s("query") })),
        _ => {
            let mut input = args.clone();
            if let Some(o) = input.as_object_mut() {
                o.remove("toolAction");
                o.remove("toolSummary");
            }
            (name.to_string(), if input.is_object() { input } else { json!({}) })
        }
    }
}
