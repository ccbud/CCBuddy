use axum::http::HeaderMap;
use serde_json::{json, Value};

fn redact_value(key: &str, val: &str) -> String {
    let k = key.to_ascii_lowercase();
    if matches!(k.as_str(), "authorization" | "x-api-key" | "cookie" | "set-cookie" | "proxy-authorization" | "x-goog-api-key") {
        "••••••（已隐藏）".to_string()
    } else {
        val.to_string()
    }
}
pub(super) fn redact_headers(h: &HeaderMap) -> Value {
    let mut o = serde_json::Map::new();
    for (k, v) in h.iter() {
        o.insert(k.as_str().to_string(), Value::String(redact_value(k.as_str(), v.to_str().unwrap_or(""))));
    }
    Value::Object(o)
}
pub(super) fn vec_headers(pairs: &[(String, String)]) -> Value {
    let mut o = serde_json::Map::new();
    for (k, v) in pairs {
        o.insert(k.clone(), Value::String(redact_value(k, v)));
    }
    Value::Object(o)
}
pub(super) fn cap_text(bytes: &[u8], cap: usize) -> Value {
    let total = bytes.len();
    let end = total.min(cap);
    json!({ "text": String::from_utf8_lossy(&bytes[..end]), "bytes": total, "truncated": total.saturating_sub(cap) })
}

pub(super) fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

pub(super) const HOP_BY_HOP_REQ: &[&str] = &[
    "host", "content-length", "authorization", "x-api-key", "accept-encoding", "cookie",
    "proxy-authorization", "connection", "proxy-connection", "transfer-encoding",
];
pub(super) const HOP_BY_HOP_RES: &[&str] = &[
    "content-length", "transfer-encoding", "content-encoding", "connection", "keep-alive",
    "proxy-authenticate", "proxy-connection", "set-cookie",
];
