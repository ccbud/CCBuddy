use crate::config::{GatewayConfig, ManagementConfig};
use axum::http::{header, HeaderMap};
use base64::Engine;
use subtle::ConstantTimeEq;

pub fn management_authorized(headers: &HeaderMap, config: &ManagementConfig) -> bool {
    let Some(value) = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
    else {
        return false;
    };
    if let Some(token) = value.strip_prefix("Bearer ") {
        return config
            .bearer_token
            .as_deref()
            .is_some_and(|expected| secret_eq(token, expected));
    }
    let Some(encoded) = value.strip_prefix("Basic ") else {
        return false;
    };
    let Ok(decoded) = base64::engine::general_purpose::STANDARD.decode(encoded) else {
        return false;
    };
    let Ok(credentials) = std::str::from_utf8(&decoded) else {
        return false;
    };
    let Some((username, password)) = credentials.split_once(':') else {
        return false;
    };
    config.basic.as_ref().is_some_and(|expected| {
        secret_eq(username, &expected.username) && secret_eq(password, &expected.password)
    })
}

pub fn inference_authorized(headers: &HeaderMap, config: &GatewayConfig) -> bool {
    if !config.require_token {
        return true;
    }
    let bearer = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    let api_key = headers
        .get("x-api-key")
        .or_else(|| headers.get("x-goog-api-key"))
        .and_then(|value| value.to_str().ok());
    bearer
        .or(api_key)
        .is_some_and(|candidate| secret_eq(candidate, &config.gateway_token))
}

fn secret_eq(candidate: &str, expected: &str) -> bool {
    let candidate = candidate.as_bytes();
    let expected = expected.as_bytes();
    candidate.len() == expected.len() && candidate.ct_eq(expected).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{BasicCredentials, ManagementConfig};

    #[test]
    fn accepts_bearer_and_basic_without_cross_accepting() {
        let config = ManagementConfig {
            port: 0,
            bearer_token: Some("0123456789abcdef0123456789abcdef".into()),
            basic: Some(BasicCredentials {
                username: "admin".into(),
                password: "fedcba9876543210fedcba9876543210".into(),
            }),
        };
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            "Bearer 0123456789abcdef0123456789abcdef".parse().unwrap(),
        );
        assert!(management_authorized(&headers, &config));
        headers.insert(
            header::AUTHORIZATION,
            "Basic YWRtaW46ZmVkY2JhOTg3NjU0MzIxMGZlZGNiYTk4NzY1NDMyMTA="
                .parse()
                .unwrap(),
        );
        assert!(management_authorized(&headers, &config));
        headers.insert(header::AUTHORIZATION, "Bearer wrong".parse().unwrap());
        assert!(!management_authorized(&headers, &config));
    }
}
