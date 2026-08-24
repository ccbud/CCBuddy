use crate::error::GatewayError;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::Read;
use std::path::Path;
use url::Url;

const MAX_CONFIG_BYTES: u64 = 1_048_576;

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewayConfig {
    #[serde(default = "default_public_port", alias = "port")]
    pub public_port: u16,
    pub management: ManagementConfig,
    #[serde(default)]
    pub require_token: bool,
    #[serde(default)]
    pub gateway_token: String,
    #[serde(default)]
    pub active_provider_id: Option<String>,
    #[serde(default)]
    pub providers: Vec<ProviderConfig>,
    #[serde(default)]
    pub failover: FailoverConfig,
    #[serde(default, alias = "retry429")]
    pub retry: RetryConfig,
    #[serde(default)]
    pub circuit_breaker: CircuitConfig,
    #[serde(default = "default_monitor_capacity")]
    pub monitor_capacity: usize,
    #[serde(default = "default_request_body_limit")]
    pub request_body_limit_bytes: usize,
    #[serde(default = "default_response_body_limit")]
    pub response_body_limit_bytes: usize,
    #[serde(default = "default_streaming_first_byte_timeout")]
    pub streaming_first_byte_timeout: u64,
    #[serde(default = "default_streaming_idle_timeout")]
    pub streaming_idle_timeout: u64,
    #[serde(default)]
    pub insecure_skip_verify: bool,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ManagementConfig {
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub bearer_token: Option<String>,
    #[serde(default)]
    pub basic: Option<BasicCredentials>,
}

#[derive(Clone, Deserialize, Serialize)]
pub struct BasicCredentials {
    pub username: String,
    pub password: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderConfig {
    pub id: String,
    pub name: String,
    pub base_url: String,
    #[serde(default)]
    pub auth_token: String,
    #[serde(default)]
    pub default_model: String,
    #[serde(default)]
    pub small_fast_model: String,
    #[serde(default = "default_true")]
    pub map_default_models: bool,
    #[serde(default)]
    pub protocol: WireProtocol,
    #[serde(default)]
    pub models: Vec<ModelMapping>,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub headers: HashMap<String, String>,
    #[serde(default = "default_upstream_timeout")]
    pub timeout_seconds: u64,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum WireProtocol {
    #[default]
    Anthropic,
    OpenaiChat,
    OpenaiResponses,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ModelMapping {
    pub alias: String,
    pub upstream: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FailoverConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default, alias = "providerIds")]
    pub provider_ids: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RetryConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_retry_max", alias = "max", alias = "maxAttempts")]
    pub max_retries: u32,
    #[serde(default = "default_retry_base", alias = "baseMs")]
    pub base_ms: u64,
    #[serde(default = "default_retry_cap")]
    pub max_backoff_ms: u64,
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            max_retries: default_retry_max(),
            base_ms: default_retry_base(),
            max_backoff_ms: default_retry_cap(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CircuitConfig {
    #[serde(default = "default_failure_threshold")]
    pub failure_threshold: u32,
    #[serde(default = "default_success_threshold")]
    pub success_threshold: u32,
    #[serde(default = "default_circuit_timeout")]
    pub timeout_seconds: u64,
    #[serde(default = "default_error_rate")]
    pub error_rate_threshold: f64,
    #[serde(default = "default_min_requests")]
    pub min_requests: u32,
}

impl Default for CircuitConfig {
    fn default() -> Self {
        Self {
            failure_threshold: default_failure_threshold(),
            success_threshold: default_success_threshold(),
            timeout_seconds: default_circuit_timeout(),
            error_rate_threshold: default_error_rate(),
            min_requests: default_min_requests(),
        }
    }
}

impl GatewayConfig {
    pub fn load_private(path: &Path) -> Result<Self, GatewayError> {
        let mut file = open_private_file(path)?;
        let metadata = file.metadata()?;
        if metadata.len() > MAX_CONFIG_BYTES {
            return Err(GatewayError::Config(
                "configuration file is too large".into(),
            ));
        }
        let mut bytes = Vec::with_capacity(metadata.len() as usize);
        file.read_to_end(&mut bytes)?;
        let config: Self = serde_json::from_slice(&bytes)
            .map_err(|error| GatewayError::Config(format!("invalid JSON: {error}")))?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<(), GatewayError> {
        if self.public_port == self.management.port && self.public_port != 0 {
            return Err(GatewayError::Config(
                "public and management ports must be different".into(),
            ));
        }
        self.management.validate()?;
        if self.require_token && self.gateway_token.trim().is_empty() {
            return Err(GatewayError::Config(
                "gatewayToken is required when requireToken is enabled".into(),
            ));
        }
        if self.providers.is_empty() {
            return Err(GatewayError::Config(
                "at least one provider is required".into(),
            ));
        }
        let mut ids = HashSet::new();
        for provider in &self.providers {
            provider.validate()?;
            if !ids.insert(provider.id.as_str()) {
                return Err(GatewayError::Config(format!(
                    "duplicate provider id: {}",
                    provider.id
                )));
            }
        }
        if let Some(active) = self.active_provider_id.as_deref() {
            if !ids.contains(active) {
                return Err(GatewayError::Config(format!(
                    "active provider does not exist: {active}"
                )));
            }
        }
        if self.failover.enabled {
            if self.failover.provider_ids.is_empty() {
                return Err(GatewayError::Config(
                    "enabled failover requires a non-empty providerIds queue".into(),
                ));
            }
            let mut queued = HashSet::new();
            for id in &self.failover.provider_ids {
                if !ids.contains(id.as_str()) {
                    return Err(GatewayError::Config(format!(
                        "failover provider does not exist: {id}"
                    )));
                }
                if !queued.insert(id) {
                    return Err(GatewayError::Config(format!(
                        "duplicate failover provider id: {id}"
                    )));
                }
            }
        }
        if self.retry.max_retries > 10 || self.retry.base_ms > 10_000 {
            return Err(GatewayError::Config(
                "retry settings exceed safety limits".into(),
            ));
        }
        if self.retry.max_backoff_ms < self.retry.base_ms || self.retry.max_backoff_ms > 120_000 {
            return Err(GatewayError::Config("invalid retry maxBackoffMs".into()));
        }
        if self.circuit_breaker.failure_threshold == 0
            || self.circuit_breaker.success_threshold == 0
            || self.circuit_breaker.timeout_seconds == 0
            || self.circuit_breaker.min_requests == 0
            || !(0.0..=1.0).contains(&self.circuit_breaker.error_rate_threshold)
        {
            return Err(GatewayError::Config(
                "invalid circuit-breaker settings".into(),
            ));
        }
        if !(16..=10_000).contains(&self.monitor_capacity) {
            return Err(GatewayError::Config(
                "monitorCapacity must be between 16 and 10000".into(),
            ));
        }
        if !(1_024..=64 * 1_024 * 1_024).contains(&self.request_body_limit_bytes) {
            return Err(GatewayError::Config("invalid request body limit".into()));
        }
        if !(1_024..=128 * 1_024 * 1_024).contains(&self.response_body_limit_bytes) {
            return Err(GatewayError::Config("invalid response body limit".into()));
        }
        if self.streaming_first_byte_timeout > 3_600 || self.streaming_idle_timeout > 3_600 {
            return Err(GatewayError::Config(
                "streaming timeouts must not exceed 3600 seconds".into(),
            ));
        }
        Ok(())
    }

    pub fn provider(&self, id: &str) -> Option<&ProviderConfig> {
        self.providers
            .iter()
            .find(|provider| provider.id == id && provider.enabled)
    }

    pub fn ordered_provider_ids(&self) -> Vec<String> {
        if self.failover.enabled {
            return self
                .failover
                .provider_ids
                .iter()
                .filter(|id| self.provider(id).is_some())
                .cloned()
                .collect();
        }
        self.active_provider_id
            .as_deref()
            .and_then(|id| self.provider(id))
            .or_else(|| self.providers.iter().find(|provider| provider.enabled))
            .map(|provider| vec![provider.id.clone()])
            .unwrap_or_default()
    }
}

impl ManagementConfig {
    fn validate(&self) -> Result<(), GatewayError> {
        if self
            .bearer_token
            .as_deref()
            .is_some_and(|token| !is_strong_secret(token))
        {
            return Err(GatewayError::Config(
                "management bearer token must contain at least 32 non-whitespace characters".into(),
            ));
        }
        if self.basic.as_ref().is_some_and(|credentials| {
            credentials.username.trim().is_empty() || !is_strong_secret(&credentials.password)
        }) {
            return Err(GatewayError::Config(
                "management Basic credentials require a username and a 32-character password"
                    .into(),
            ));
        }
        if self.bearer_token.is_none() && self.basic.is_none() {
            return Err(GatewayError::Config(
                "management requires a bearer token or Basic password of at least 32 characters"
                    .into(),
            ));
        }
        Ok(())
    }
}

impl ProviderConfig {
    fn validate(&self) -> Result<(), GatewayError> {
        if self.id.trim().is_empty() || self.name.trim().is_empty() {
            return Err(GatewayError::Config(
                "provider id and name must not be empty".into(),
            ));
        }
        let url = Url::parse(&self.base_url).map_err(|error| {
            GatewayError::Config(format!("invalid baseUrl for {}: {error}", self.id))
        })?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
        {
            return Err(GatewayError::Config(format!(
                "unsafe baseUrl for {}",
                self.id
            )));
        }
        if self.timeout_seconds == 0 || self.timeout_seconds > 3_600 {
            return Err(GatewayError::Config(format!(
                "invalid timeout for {}",
                self.id
            )));
        }
        for (name, value) in &self.headers {
            http::header::HeaderName::from_bytes(name.as_bytes()).map_err(|_| {
                GatewayError::Config(format!("invalid header name for {}", self.id))
            })?;
            http::header::HeaderValue::from_str(value).map_err(|_| {
                GatewayError::Config(format!("invalid header value for {}", self.id))
            })?;
        }
        Ok(())
    }

    pub fn resolve_model(&self, requested: Option<&str>) -> Option<String> {
        let requested = requested.unwrap_or_default();
        if let Some(mapping) = self
            .models
            .iter()
            .find(|mapping| mapping.alias == requested)
        {
            return Some(mapping.upstream.clone());
        }
        if self.map_default_models {
            let lower = requested.to_ascii_lowercase();
            if (lower.contains("haiku") || lower.ends_with("-mini"))
                && !self.small_fast_model.is_empty()
            {
                return Some(self.small_fast_model.clone());
            }
            if !self.default_model.is_empty()
                && (requested.is_empty()
                    || lower.contains("sonnet")
                    || lower.contains("opus")
                    || lower.starts_with("gpt-"))
            {
                return Some(self.default_model.clone());
            }
        }
        (!requested.is_empty()).then(|| requested.to_string())
    }
}

impl WireProtocol {
    pub fn as_ccbud_wire(self) -> crate::protocol::Wire {
        match self {
            Self::Anthropic => crate::protocol::Wire::Anthropic,
            Self::OpenaiChat => crate::protocol::Wire::OpenAiChat,
            Self::OpenaiResponses => crate::protocol::Wire::OpenAiResponses,
        }
    }
}

fn is_strong_secret(value: &str) -> bool {
    value.len() >= 32 && !value.chars().any(char::is_whitespace)
}

#[cfg(unix)]
fn open_private_file(path: &Path) -> Result<File, GatewayError> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| GatewayError::Config(format!("cannot securely open config: {error}")))?;
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file() {
        return Err(GatewayError::Config(
            "configuration path is not a regular file".into(),
        ));
    }
    if metadata.mode() & 0o077 != 0 {
        return Err(GatewayError::Config(
            "configuration permissions must be owner-only (0600 or stricter)".into(),
        ));
    }
    let effective_uid = unsafe { libc::geteuid() };
    if metadata.uid() != effective_uid {
        return Err(GatewayError::Config(
            "configuration file is not owned by the current user".into(),
        ));
    }
    Ok(file)
}

#[cfg(not(unix))]
fn open_private_file(path: &Path) -> Result<File, GatewayError> {
    let metadata = std::fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
        return Err(GatewayError::Config(
            "configuration path is not a regular file".into(),
        ));
    }
    File::open(path).map_err(GatewayError::Io)
}

fn default_true() -> bool {
    true
}
fn default_public_port() -> u16 {
    8788
}
fn default_monitor_capacity() -> usize {
    500
}
fn default_request_body_limit() -> usize {
    64 * 1_024 * 1_024
}
fn default_response_body_limit() -> usize {
    128 * 1_024 * 1_024
}
fn default_streaming_first_byte_timeout() -> u64 {
    60
}
fn default_streaming_idle_timeout() -> u64 {
    120
}
fn default_upstream_timeout() -> u64 {
    600
}
fn default_retry_max() -> u32 {
    3
}
fn default_retry_base() -> u64 {
    500
}
fn default_retry_cap() -> u64 {
    30_000
}
fn default_failure_threshold() -> u32 {
    4
}
fn default_success_threshold() -> u32 {
    2
}
fn default_circuit_timeout() -> u64 {
    60
}
fn default_error_rate() -> f64 {
    0.6
}
fn default_min_requests() -> u32 {
    10
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn valid_json() -> serde_json::Value {
        serde_json::json!({
            "publicPort": 8788,
            "management": { "port": 0, "bearerToken": "0123456789abcdef0123456789abcdef" },
            "activeProviderId": "one",
            "providers": [{
                "id": "one", "name": "One", "baseUrl": "https://example.com/v1",
                "protocol": "openai-chat"
            }]
        })
    }

    #[test]
    fn validates_ordered_failover_queue() {
        let mut value = valid_json();
        value["failover"] = serde_json::json!({"enabled": true, "providerIds": ["missing"]});
        let config: GatewayConfig = serde_json::from_value(value).unwrap();
        assert!(config
            .validate()
            .unwrap_err()
            .to_string()
            .contains("does not exist"));
    }

    #[test]
    fn enabled_failover_uses_the_declared_queue_order() {
        let mut value = valid_json();
        value["providers"] = serde_json::json!([
            {"id":"one","name":"One","baseUrl":"https://one.example/v1"},
            {"id":"two","name":"Two","baseUrl":"https://two.example/v1"}
        ]);
        value["failover"] = serde_json::json!({"enabled":true,"providerIds":["two","one"]});
        let config: GatewayConfig = serde_json::from_value(value).unwrap();

        assert_eq!(config.ordered_provider_ids(), ["two", "one"]);
    }

    #[test]
    fn enabled_failover_does_not_prepend_the_active_provider() {
        let mut value = valid_json();
        value["providers"] = serde_json::json!([
            {"id":"one","name":"One","baseUrl":"https://one.example/v1"},
            {"id":"two","name":"Two","baseUrl":"https://two.example/v1"}
        ]);
        value["failover"] = serde_json::json!({"enabled":true,"providerIds":["two"]});
        let config: GatewayConfig = serde_json::from_value(value).unwrap();

        assert_eq!(config.ordered_provider_ids(), ["two"]);
    }

    #[test]
    fn invalid_or_disabled_active_provider_is_not_forced_into_the_queue() {
        let mut invalid = valid_json();
        invalid["activeProviderId"] = serde_json::json!("missing");
        invalid["failover"] = serde_json::json!({"enabled":true,"providerIds":["one"]});
        let invalid: GatewayConfig = serde_json::from_value(invalid).unwrap();
        assert_eq!(invalid.ordered_provider_ids(), ["one"]);

        let mut disabled = valid_json();
        disabled["providers"] = serde_json::json!([
            {"id":"one","name":"One","baseUrl":"https://one.example/v1","enabled":false},
            {"id":"two","name":"Two","baseUrl":"https://two.example/v1"}
        ]);
        disabled["failover"] = serde_json::json!({"enabled":true,"providerIds":["one","two"]});
        let disabled: GatewayConfig = serde_json::from_value(disabled).unwrap();
        assert_eq!(disabled.ordered_provider_ids(), ["two"]);
    }

    #[test]
    fn rejects_a_weak_secondary_management_credential() {
        let mut value = valid_json();
        value["management"]["basic"] = serde_json::json!({
            "username": "admin",
            "password": "short"
        });
        let config: GatewayConfig = serde_json::from_value(value).unwrap();
        assert!(config
            .validate()
            .unwrap_err()
            .to_string()
            .contains("Basic credentials"));
    }

    #[test]
    fn maps_aliases_before_default_tiers() {
        let config: GatewayConfig = serde_json::from_value(valid_json()).unwrap();
        let provider = &config.providers[0];
        assert_eq!(
            provider.resolve_model(Some("custom")),
            Some("custom".into())
        );
    }

    #[cfg(unix)]
    #[test]
    fn private_loader_rejects_group_readable_files() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("gateway.json");
        let mut file = File::create(&path).unwrap();
        file.write_all(valid_json().to_string().as_bytes()).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
        let error = match GatewayConfig::load_private(&path) {
            Ok(_) => panic!("group-readable config was accepted"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("owner-only"));
    }
}
