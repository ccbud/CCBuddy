//! Local model discovery responses used by Claude- and Codex-family clients.
//!
//! Upstream model-list endpoints are not consistent enough to use as the localhost gateway's
//! reachability contract. The response keeps CC Buddy's aliases and tier identities while also
//! exposing the top-level `models` field probed by current Codex releases.

use crate::config::GatewayConfig;
use axum::http::HeaderMap;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::OnceLock;

const CLAUDE_TIER_MODELS: &[&str] = &[
    "claude-fable-5",
    "claude-opus-4-8",
    "claude-sonnet-5",
    "claude-haiku-4-5",
    "claude-haiku-4-5-20251001",
];
const CODEX_TIER_MODELS: &[&str] = &["gpt-5.4", "gpt-5.4-mini"];
const CODEX_NATIVE_RESPONSES_TEMPLATE: &str = r#"{
  "slug": "native-responses-template",
  "display_name": "native-responses-template",
  "description": "native-responses-template",
  "base_instructions": "You are Codex, a coding agent. You and the user share the same workspace and collaborate to achieve the user's goals.",
  "default_reasoning_level": "high",
  "supported_reasoning_levels": [
    {"effort": "none", "description": "Disable Thinking"},
    {"effort": "high", "description": "Enabled Thinking"}
  ],
  "shell_type": "shell_command",
  "visibility": "list",
  "supported_in_api": true,
  "priority": 0,
  "supports_reasoning_summaries": true,
  "default_reasoning_summary": "none",
  "support_verbosity": false,
  "truncation_policy": {"mode": "bytes", "limit": 10000},
  "supports_parallel_tool_calls": false,
  "supports_image_detail_original": false,
  "context_window": 262144,
  "max_context_window": 262144,
  "effective_context_window_percent": 95,
  "experimental_supported_tools": [],
  "input_modalities": ["text", "image"],
  "supports_search_tool": false
}"#;

pub fn is_models_request(method: &http::Method, path: &str) -> bool {
    *method == http::Method::GET && matches!(path.trim_end_matches('/'), "/models" | "/v1/models")
}

pub fn client_is_codex(headers: &HeaderMap) -> bool {
    ["user-agent", "originator"].iter().any(|name| {
        headers
            .get(*name)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.to_ascii_lowercase().contains("codex"))
    })
}

pub fn synthesize(config: &GatewayConfig, codex_client: bool) -> Value {
    let mut ids = Vec::new();
    let mut seen = HashSet::new();
    let mut push = |value: &str| {
        let value = value.trim();
        if !value.is_empty() && seen.insert(value.to_string()) {
            ids.push(value.to_string());
        }
    };

    for provider in &config.providers {
        for mapping in &provider.models {
            push(&mapping.alias);
        }
    }
    if let Some(active) = config
        .active_provider_id
        .as_deref()
        .and_then(|id| config.provider(id))
        .or_else(|| config.providers.iter().find(|provider| provider.enabled))
    {
        push(&active.default_model);
        push(&active.small_fast_model);
    }
    for model in if codex_client {
        CODEX_TIER_MODELS
    } else {
        CLAUDE_TIER_MODELS
    } {
        push(model);
    }

    let data: Vec<Value> = ids
        .iter()
        .map(|id| {
            json!({
                "object": "model",
                "type": "model",
                "id": id,
                "display_name": id,
                "created": 0,
                "created_at": "2025-01-01T00:00:00Z",
                "owned_by": "ccbud"
            })
        })
        .collect();
    let models: Vec<Value> = if codex_client {
        ids.iter()
            .enumerate()
            .map(|(priority, id)| {
                let mut model = codex_native_responses_template().clone();
                let object = model
                    .as_object_mut()
                    .expect("Codex catalog template must be an object");
                object.insert("slug".into(), Value::String(id.clone()));
                object.insert("display_name".into(), Value::String(id.clone()));
                object.insert(
                    "description".into(),
                    Value::String(format!("CC Buddy gateway model {id}")),
                );
                object.insert("priority".into(), json!(priority));
                model
            })
            .collect()
    } else {
        Vec::new()
    };
    json!({
        "object": "list",
        "data": data,
        "has_more": false,
        "first_id": ids.first(),
        "last_id": ids.last(),
        "models": models
    })
}

fn codex_native_responses_template() -> &'static Value {
    static TEMPLATE: OnceLock<Value> = OnceLock::new();
    TEMPLATE.get_or_init(|| {
        serde_json::from_str(CODEX_NATIVE_RESPONSES_TEMPLATE)
            .expect("embedded Codex catalog template must be valid JSON")
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::GatewayConfig;

    fn config() -> GatewayConfig {
        serde_json::from_value(json!({
            "publicPort": 8788,
            "management": {
                "port": 0,
                "bearerToken": "0123456789abcdef0123456789abcdef"
            },
            "activeProviderId": "one",
            "providers": [{
                "id": "one",
                "name": "One",
                "baseUrl": "https://example.com/v1",
                "defaultModel": "upstream-primary",
                "smallFastModel": "upstream-fast",
                "models": [{"alias": "friendly", "upstream": "upstream-primary"}]
            }]
        }))
        .unwrap()
    }

    #[test]
    fn model_list_keeps_aliases_tiers_and_codex_probe_shape() {
        let value = synthesize(&config(), true);
        let ids: Vec<&str> = value["data"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|entry| entry["id"].as_str())
            .collect();
        assert!(ids.contains(&"friendly"));
        assert!(ids.contains(&"upstream-primary"));
        assert!(ids.contains(&"gpt-5.4"));
        let models = value["models"].as_array().unwrap();
        assert_eq!(models.len(), ids.len());
        let friendly = models
            .iter()
            .find(|entry| entry["slug"] == "friendly")
            .unwrap();
        assert_eq!(friendly["display_name"], "friendly");
        assert!(friendly["description"]
            .as_str()
            .unwrap()
            .contains("friendly"));
        assert!(friendly["base_instructions"].as_str().is_some());
        assert_eq!(friendly["shell_type"], "shell_command");
        assert_eq!(friendly["truncation_policy"]["mode"], "bytes");
        assert_eq!(friendly["input_modalities"], json!(["text", "image"]));
        assert!(friendly["supports_reasoning_summaries"].as_bool().unwrap());
    }

    #[test]
    fn non_codex_model_list_keeps_openai_data_without_claiming_codex_catalog() {
        let value = synthesize(&config(), false);
        assert!(!value["data"].as_array().unwrap().is_empty());
        assert_eq!(value["models"], json!([]));
    }

    #[test]
    fn route_detection_is_exact_and_client_detection_accepts_originator() {
        assert!(is_models_request(&http::Method::GET, "/v1/models/"));
        assert!(!is_models_request(&http::Method::GET, "/v1/models/custom"));
        let mut headers = HeaderMap::new();
        headers.insert("originator", "codex_cli_rs".parse().unwrap());
        assert!(client_is_codex(&headers));
    }
}
