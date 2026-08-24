// The wire protocol a request or provider speaks, its endpoint URLs, and the `/v1` compatibility
// fallback (some providers publish an unversioned base that 404s until `/v1` is appended).

use axum::http::Uri;

/// A wire protocol a request or provider speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Wire {
    Anthropic,
    OpenAiChat,
    OpenAiResponses,
}

impl Wire {
    /// The provider's declared protocol (config `protocol` field). Unknown / absent → Anthropic,
    /// which is today's passthrough default.
    pub fn from_provider(s: Option<&str>) -> Wire {
        match s {
            Some("openai-chat") => Wire::OpenAiChat,
            Some("openai-responses") => Wire::OpenAiResponses,
            _ => Wire::Anthropic,
        }
    }

    /// The client's protocol, inferred from the inbound request path. Claude Code hits
    /// `/v1/messages`; an OpenAI/Codex client hits `/v1/chat/completions`, `/v1/responses`,
    /// or the Responses-native `/v1/alpha/search` endpoint.
    pub fn from_request_path(uri: &Uri) -> Wire {
        let p = uri.path().trim_end_matches('/');
        if p.ends_with("/responses")
            || p.ends_with("/responses/compact")
            || p.ends_with("/alpha/search")
        {
            Wire::OpenAiResponses
        } else if p.contains("/chat/completions") {
            Wire::OpenAiChat
        } else {
            Wire::Anthropic
        }
    }

    /// Short human label for exchange records / monitor UI.
    pub fn label(self) -> &'static str {
        match self {
            Wire::Anthropic => "anthropic",
            Wire::OpenAiChat => "openai-chat",
            Wire::OpenAiResponses => "openai-responses",
        }
    }

    /// The bare endpoint appended to the provider's configured baseUrl.
    pub fn endpoint_path(self) -> &'static str {
        match self {
            Wire::Anthropic => "/messages",
            Wire::OpenAiChat => "/chat/completions",
            Wire::OpenAiResponses => "/responses",
        }
    }

    /// Full upstream URL, treating the configured baseUrl as authoritative.
    pub fn upstream_url(self, base_url: &str) -> String {
        let base = base_url.trim_end_matches('/');
        format!("{}{}", base, self.endpoint_path())
    }

    /// Compatibility URL for configurations created when ccbud implicitly inserted `/v1`.
    /// A versioned baseUrl (`v1`, `v4`, `v1beta`, …), or Google's `/openai` compatibility root,
    /// must never receive another version segment.
    pub fn v1_fallback_url(self, base_url: &str) -> Option<String> {
        let base = base_url.trim_end_matches('/');
        if base_url_has_version_suffix(base_url)
            || (self == Wire::OpenAiChat && base.ends_with("/openai"))
        {
            return None;
        }
        Some(format!("{}/v1{}", base, self.endpoint_path()))
    }

    /// Match only inference endpoints that may be safely rebased onto a provider URL.
    /// Models, count_tokens, HEAD, and unknown routes keep the generic passthrough path.
    pub fn from_request_endpoint(path: &str) -> Option<Wire> {
        match path.trim_end_matches('/') {
            "/messages" | "/v1/messages" => Some(Wire::Anthropic),
            "/chat/completions"
            | "/v1/chat/completions"
            | "/v1/v1/chat/completions"
            | "/codex/v1/chat/completions" => Some(Wire::OpenAiChat),
            "/responses"
            | "/v1/responses"
            | "/v1/v1/responses"
            | "/codex/v1/responses"
            | "/responses/compact"
            | "/v1/responses/compact"
            | "/v1/v1/responses/compact"
            | "/codex/v1/responses/compact"
            | "/alpha/search"
            | "/v1/alpha/search"
            | "/v1/v1/alpha/search"
            | "/codex/v1/alpha/search" => Some(Wire::OpenAiResponses),
            _ => None,
        }
    }

    pub fn request_endpoint_path(self, inbound_path: &str) -> &'static str {
        let inbound_path = inbound_path.trim_end_matches('/');
        if self == Wire::OpenAiResponses && inbound_path.ends_with("/alpha/search") {
            "/alpha/search"
        } else if self == Wire::OpenAiResponses && inbound_path.ends_with("/responses/compact") {
            "/responses/compact"
        } else {
            self.endpoint_path()
        }
    }

    pub fn upstream_url_for_request(self, base_url: &str, inbound_path: &str) -> String {
        let base = base_url.trim_end_matches('/');
        format!("{}{}", base, self.request_endpoint_path(inbound_path))
    }

    pub fn v1_fallback_url_for_request(self, base_url: &str, inbound_path: &str) -> Option<String> {
        let base = base_url.trim_end_matches('/');
        if base_url_has_version_suffix(base_url)
            || (self == Wire::OpenAiChat && base.ends_with("/openai"))
        {
            return None;
        }
        Some(format!(
            "{}/v1{}",
            base,
            self.request_endpoint_path(inbound_path)
        ))
    }
}

fn base_url_has_version_suffix(base_url: &str) -> bool {
    let clean = base_url
        .split(['?', '#'])
        .next()
        .unwrap_or(base_url)
        .trim_end_matches('/');
    let after_authority = clean
        .split_once("://")
        .map(|(_, rest)| rest)
        .unwrap_or(clean);
    let Some((_, path)) = after_authority.split_once('/') else {
        return false;
    };
    let Some(segment) = path.rsplit('/').find(|segment| !segment.is_empty()) else {
        return false;
    };
    let mut chars = segment.chars();
    matches!(chars.next(), Some('v' | 'V')) && matches!(chars.next(), Some(c) if c.is_ascii_digit())
}

/// Statuses commonly used by upstreams for an unrecognized or unsupported endpoint path.
/// Authentication, validation, payload-size, and rate-limit errors intentionally do not qualify.
pub fn should_try_v1_fallback(status: u16) -> bool {
    matches!(status, 400 | 404 | 405)
}
