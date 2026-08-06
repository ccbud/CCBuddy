use axum::{
    body::Body,
    http::{StatusCode, Uri},
    response::Response,
};
use serde_json::{json, Value};

use super::sse::is_responses_compact_path;

pub(super) fn retry_delay(retry_after: Option<&str>, attempt: i64, base: i64) -> u64 {
    let cap = 30_000u64;
    if let Some(ra) = retry_after {
        let s = ra.trim();
        if let Ok(n) = s.parse::<u64>() {
            return (n.saturating_mul(1000)).min(cap);
        }
        // HTTP-date form (RFC 7231 IMF-fixdate) — honor the absolute time the upstream named
        // (proxy.js parity). chrono is already a dep, so no extra crate is pulled in for this.
        if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(s, "%a, %d %b %Y %H:%M:%S GMT") {
            let ms = (dt.and_utc() - chrono::Utc::now()).num_milliseconds().max(0) as u64;
            return ms.min(cap);
        }
    }
    let base = if base > 0 { base as u64 } else { 500 };
    base.saturating_mul(2u64.saturating_pow(attempt.clamp(0, 20) as u32))
        .min(8000)
}

pub(super) fn build_target(base_url: &str, uri: &Uri) -> Option<String> {
    if base_url.is_empty() {
        return None;
    }
    let base = base_url.trim_end_matches('/');
    let path = uri.path();
    let query = uri.query().map(|q| format!("?{}", q)).unwrap_or_default();
    // If the provider baseUrl already carries a path prefix (e.g. ".../v1") and the
    // inbound path repeats it (e.g. "/v1/responses"), collapse the overlap so we don't
    // forward to ".../v1/v1/responses". This is what bites an openai-* provider whose
    // baseUrl ends in /v1 (incl. the sidecar plugins) on same-protocol passthrough.
    // Segment-aware so a "/v1" base won't eat a "/v1beta" path.
    let base_path = base_url_path(base).trim_end_matches('/');
    let path_out: &str = if base_path.is_empty() || base_path == "/" {
        path
    } else if path == base_path {
        ""
    } else {
        match path.strip_prefix(base_path) {
            Some(rest) if rest.starts_with('/') => rest,
            _ => path,
        }
    };
    Some(format!("{}{}{}", base, path_out, query))
}

/// Resolve one of the three primary API endpoints against the configured base URL. The base is
/// authoritative: an inbound `/v1/...` path does not cause ccbud to insert `/v1` upstream.
pub(super) fn endpoint_targets(base_url: &str, uri: &Uri) -> Option<(String, Option<String>)> {
    if base_url.trim().is_empty() {
        return None;
    }
    let wire = crate::protocol::Wire::from_request_endpoint(uri.path())?;
    let with_query = |mut url: String| {
        if let Some(query) = uri.query() {
            url.push('?');
            url.push_str(query);
        }
        url
    };
    Some((
        with_query(wire.upstream_url_for_request(base_url, uri.path())),
        wire.v1_fallback_url_for_request(base_url, uri.path()).map(with_query),
    ))
}

/// Standalone Responses compaction returns a distinct `response.compaction` object whose output
/// is the canonical replacement context window. Chat and Anthropic upstreams cannot provide that
/// contract through the ordinary response transcoder, so fail explicitly instead of turning a
/// compact request into an unrelated model turn. Responses providers keep the passthrough path.
pub(super) fn cross_wire_compact_error(path: &str, provider_wire: crate::protocol::Wire) -> Option<Response> {
    (is_responses_compact_path(path)
        && provider_wire != crate::protocol::Wire::OpenAiResponses)
        .then(|| {
            error_response(
                StatusCode::NOT_IMPLEMENTED,
                "CC Buddy: /v1/responses/compact requires an openai-responses provider; cross-protocol compaction is not supported",
                "invalid_request_error",
            )
        })
}

/// The path component of a base URL (everything after scheme://authority), or "".
fn base_url_path(base: &str) -> &str {
    let after_scheme = base.split_once("://").map(|(_, rest)| rest).unwrap_or(base);
    match after_scheme.find('/') {
        Some(i) => &after_scheme[i..],
        None => "",
    }
}

pub(super) fn error_response(status: StatusCode, msg: &str, etype: &str) -> Response {
    json_response(status, &json!({ "type": "error", "error": { "type": etype, "message": msg } }))
}
pub(super) fn json_response(status: StatusCode, body: &Value) -> Response {
    let bytes = serde_json::to_vec(body).unwrap_or_default();
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Body::from(bytes))
        .unwrap()
}
