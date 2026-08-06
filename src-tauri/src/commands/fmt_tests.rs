use super::{ensure_hero_connect_target, format_tokens, startup_reconcile_targets};
use serde_json::json;

#[test]
fn startup_reconciliation_requires_the_targets_own_backup() {
    assert!(startup_reconcile_targets(&json!({})).is_empty());
    assert!(startup_reconcile_targets(&json!({
        "connectTargets": ["claude"],
        "claudeBackup": null
    }))
    .is_empty());
    assert!(startup_reconcile_targets(&json!({
        "connectTargets": ["codex"],
        "codexBackup": "not-a-backup"
    }))
    .is_empty());

    assert_eq!(
        startup_reconcile_targets(&json!({
            "connectTargets": ["claude", "codex"],
            "claudeBackup": { "model": null, "env": {} },
            "codexBackup": null
        })),
        vec!["claude"]
    );
    assert_eq!(
        startup_reconcile_targets(&json!({
            "connectTargets": ["claude", "codex"],
            "claudeBackup": null,
            "codexBackup": {
                "model": "gpt-5",
                "model_provider": "openai",
                "model_reasoning_effort": null
            }
        })),
        vec!["codex"]
    );
}

#[test]
fn hero_connect_defaults_to_claude_without_overriding_a_selection() {
    let mut fresh = json!({ "connectTargets": [] });
    assert!(ensure_hero_connect_target(&mut fresh));
    assert_eq!(fresh["connectTargets"], json!(["claude"]));

    let mut selected = json!({ "connectTargets": ["codex"] });
    assert!(!ensure_hero_connect_target(&mut selected));
    assert_eq!(selected["connectTargets"], json!(["codex"]));
}

#[test]
fn matches_js_format_tokens() {
    assert_eq!(format_tokens(0), "0");
    assert_eq!(format_tokens(999), "999");
    assert_eq!(format_tokens(1000), "1K");
    assert_eq!(format_tokens(1234), "1.2K");
    assert_eq!(format_tokens(9999), "10K");
    assert_eq!(format_tokens(12_345), "12K");
    assert_eq!(format_tokens(1_000_000), "1M");
    assert_eq!(format_tokens(4_900_000), "4.9M");
    assert_eq!(format_tokens(12_000_000), "12M");
    assert_eq!(format_tokens(1_000_000_000), "1B");
    assert_eq!(format_tokens(4_892_112_447), "4.9B");
}
