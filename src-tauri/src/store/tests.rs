use super::defaults::default_config;
use super::io::update_provider_base_url_to_v1;
use super::normalize::normalize;
use serde_json::json;

#[test]
fn fresh_and_legacy_configs_do_not_select_a_startup_connection() {
    assert_eq!(default_config()["connectTargets"], json!([]));
    assert_eq!(normalize(json!({}))["connectTargets"], json!([]));

    let explicit = normalize(json!({
        "connectTargets": ["codex", "claude", "codex", "invalid"]
    }));
    assert_eq!(explicit["connectTargets"], json!(["codex", "claude"]));
}

#[test]
fn normalize_sanitizes_providers_and_active() {
    let input = json!({
        "port": 9000,
        "providers": [{ "name": "X", "baseUrl": "u", "authToken": "t", "extra": "drop",
            "models": [{ "alias": "a", "upstream": "u" }, { "alias": "", "upstream": "" }] }]
    });
    let n = normalize(input);
    assert_eq!(n["port"], 9000);
    assert_eq!(n["providers"][0]["name"], "X");
    assert!(n["providers"][0].get("extra").is_none(), "unknown field must be dropped");
    assert_eq!(n["providers"][0]["models"].as_array().unwrap().len(), 1, "empty model dropped");
    assert_eq!(n["activeProviderId"], n["providers"][0]["id"], "active auto-set to first provider");
    assert!(n["historyDirs"].as_array().unwrap().iter().any(|d| d == "~/.claude"));
    assert_eq!(n["providers"][0]["protocol"], "anthropic", "protocol defaults to anthropic (passthrough)");
}

#[test]
fn provider_protocol_normalized() {
    let ok = normalize(json!({ "providers": [{ "name": "O", "protocol": "openai-chat" }] }));
    assert_eq!(ok["providers"][0]["protocol"], "openai-chat");
    // unrecognized → safe passthrough default
    let bad = normalize(json!({ "providers": [{ "name": "B", "protocol": "grpc" }] }));
    assert_eq!(bad["providers"][0]["protocol"], "anthropic");
}
#[test]
fn normalize_migrates_legacy_glm_anthropic_base_url() {
    let legacy = normalize(json!({ "providers": [{
        "name": "GLM",
        "baseUrl": "https://open.bigmodel.cn/api/anthropic/",
        "protocol": "anthropic"
    }] }));
    assert_eq!(
        legacy["providers"][0]["baseUrl"],
        "https://open.bigmodel.cn/api/anthropic/v1"
    );

    let custom = normalize(json!({ "providers": [{
        "name": "Custom",
        "baseUrl": "https://example.com/api/anthropic",
        "protocol": "anthropic"
    }] }));
    assert_eq!(custom["providers"][0]["baseUrl"], "https://example.com/api/anthropic");
}
#[test]
fn normalize_clamps_retry() {
    let n = normalize(json!({ "retry429": { "max": 999, "baseMs": 99999 } }));
    assert_eq!(n["retry429"]["max"], 10);
    assert_eq!(n["retry429"]["baseMs"], 10000);
}
#[test]
fn normalize_keeps_recycle_bin_active() {
    // Synthetic buckets must survive normalize, else history_set_active("__trash__") is
    // silently reset to "all" and the recycle bin can never be opened.
    assert_eq!(normalize(json!({ "historyActive": "__trash__" }))["historyActive"], "__trash__");
    assert_eq!(normalize(json!({ "historyActive": "__imported__" }))["historyActive"], "__imported__");
    assert_eq!(normalize(json!({ "historyActive": "bogus-dir" }))["historyActive"], "all");
}

#[test]
fn provider_base_url_v1_migration_updates_only_the_matching_url() {
    let mut config = json!({
        "port": 9000,
        "customSetting": { "keep": true },
        "providers": [
            {
                "id": "target",
                "name": "Target",
                "backend": "http",
                "baseUrl": "https://example.com/api/",
                "authToken": "secret",
                "defaultModel": "model-a",
                "models": [{ "alias": "fast", "upstream": "model-b" }]
            },
            {
                "id": "other",
                "backend": "http",
                "baseUrl": "https://other.example/api",
                "authToken": "other-secret"
            }
        ]
    });
    let before_other = config["providers"][1].clone();
    let before_settings = config["customSetting"].clone();

    assert!(update_provider_base_url_to_v1(
        &mut config,
        "target",
        "https://example.com/api/"
    ));
    assert_eq!(
        config["providers"][0]["baseUrl"],
        "https://example.com/api/v1"
    );
    assert_eq!(config["providers"][0]["authToken"], "secret");
    assert_eq!(config["providers"][0]["defaultModel"], "model-a");
    assert_eq!(
        config["providers"][0]["models"],
        json!([{ "alias": "fast", "upstream": "model-b" }])
    );
    assert_eq!(config["providers"][1], before_other);
    assert_eq!(config["customSetting"], before_settings);
    assert_eq!(config["port"], 9000);
}

#[test]
fn provider_base_url_v1_migration_requires_expected_old_url() {
    let mut config = json!({
        "providers": [{
            "id": "target",
            "backend": "http",
            "baseUrl": "https://example.com/user-edit"
        }]
    });
    let before = config.clone();

    assert!(!update_provider_base_url_to_v1(
        &mut config,
        "target",
        "https://example.com/old"
    ));
    assert_eq!(config, before);
}

#[test]
fn provider_base_url_v1_migration_skips_plugins() {
    let mut config = json!({
        "providers": [{
            "id": "target",
            "backend": "plugin",
            "baseUrl": "http://127.0.0.1:12345"
        }]
    });
    let before = config.clone();

    assert!(!update_provider_base_url_to_v1(
        &mut config,
        "target",
        "http://127.0.0.1:12345"
    ));
    assert_eq!(config, before);
}
