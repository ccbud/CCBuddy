use super::*;

#[test]
fn upstream_urls_respect_the_configured_base() {
    let cases = [
        (Wire::Anthropic, "/messages"),
        (Wire::OpenAiChat, "/chat/completions"),
        (Wire::OpenAiResponses, "/responses"),
    ];
    for (wire, endpoint) in cases {
        for base in [
            "https://example.com",
            "https://example.com/v1",
            "https://example.com/v4",
            "https://generativelanguage.googleapis.com/v1beta/openai",
        ] {
            assert_eq!(wire.upstream_url(base), format!("{}{}", base, endpoint));
        }
    }
}

#[test]
fn v1_fallback_is_only_offered_for_unversioned_bases() {
    assert_eq!(
        Wire::OpenAiChat.v1_fallback_url("https://example.com/api"),
        Some("https://example.com/api/v1/chat/completions".to_string())
    );
    for base in [
        "https://example.com/v1",
        "https://example.com/v4/",
        "https://example.com/v1beta",
        "https://example.com/V2alpha",
        "https://generativelanguage.googleapis.com/v1beta/openai",
    ] {
        assert_eq!(Wire::OpenAiChat.v1_fallback_url(base), None, "{base}");
    }
}

#[test]
fn canonical_request_endpoints_exclude_auxiliary_routes() {
    for (path, wire, canonical) in [
        (
            "/v1/messages",
            Wire::Anthropic,
            "https://example.com/v1/messages",
        ),
        (
            "/v1/chat/completions",
            Wire::OpenAiChat,
            "https://example.com/v1/chat/completions",
        ),
        (
            "/v1/responses",
            Wire::OpenAiResponses,
            "https://example.com/v1/responses",
        ),
        (
            "/v1/responses/compact",
            Wire::OpenAiResponses,
            "https://example.com/v1/responses/compact",
        ),
        (
            "/v1/v1/chat/completions",
            Wire::OpenAiChat,
            "https://example.com/v1/chat/completions",
        ),
        (
            "/v1/v1/responses",
            Wire::OpenAiResponses,
            "https://example.com/v1/responses",
        ),
        (
            "/v1/v1/responses/compact",
            Wire::OpenAiResponses,
            "https://example.com/v1/responses/compact",
        ),
        (
            "/v1/v1/alpha/search",
            Wire::OpenAiResponses,
            "https://example.com/v1/alpha/search",
        ),
        (
            "/codex/v1/alpha/search",
            Wire::OpenAiResponses,
            "https://example.com/v1/alpha/search",
        ),
        (
            "/codex/v1/chat/completions",
            Wire::OpenAiChat,
            "https://example.com/v1/chat/completions",
        ),
        (
            "/codex/v1/responses",
            Wire::OpenAiResponses,
            "https://example.com/v1/responses",
        ),
        (
            "/codex/v1/responses/compact",
            Wire::OpenAiResponses,
            "https://example.com/v1/responses/compact",
        ),
    ] {
        assert_eq!(Wire::from_request_endpoint(path), Some(wire), "{path}");
        assert_eq!(
            wire.upstream_url_for_request("https://example.com/v1", path),
            canonical,
            "{path}"
        );
    }
    assert_eq!(
        Wire::from_request_endpoint("/v1/messages/count_tokens"),
        None
    );
    assert_eq!(Wire::from_request_endpoint("/v1/models"), None);
}

#[test]
fn v1_fallback_statuses_exclude_non_path_errors() {
    for status in [400, 404, 405] {
        assert!(should_try_v1_fallback(status));
    }
    for status in [401, 403, 413, 415, 422, 429, 500] {
        assert!(!should_try_v1_fallback(status));
    }
}
