use super::config::config_path;
use super::{connect, disconnect, is_connected};
use crate::store;
use serde_json::Value;
use std::fs;

// One test (CCBUD_HOME / CCBUD_CODEX_CONFIG are process-global env, so a single sequential test
// avoids racing other tests on them).
#[test]
fn connect_disconnect_round_trip() {
    let dir = std::env::temp_dir().join(format!("ccbud-codexconn-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    let _ = fs::create_dir_all(&dir);
    std::env::set_var("CCBUD_CODEX_CONFIG", dir.join("config.toml"));
    std::env::set_var("CCBUD_HOME", dir.join("ccbud-home"));

    // --- case 1: pre-existing config with a comment + unrelated setting must survive ---
    fs::write(config_path(), "# my codex config\nmodel = \"gpt-5\"\nmodel_provider = \"openai\"\napproval_policy = \"on-request\"\n").unwrap();
    connect(4321, "ccbud-local", "z-ai/glm-5.2");
    assert!(is_connected(4321));
    let raw = fs::read_to_string(config_path()).unwrap();
    assert!(raw.contains("# my codex config"), "user comment preserved");
    assert!(raw.contains("approval_policy"), "unrelated setting preserved");
    assert!(raw.contains("[model_providers.ccbud]"));
    assert!(raw.contains("name = \"CC Buddy\""));
    assert!(raw.contains("base_url = \"http://localhost:4321/v1\""));
    assert!(raw.contains("wire_api = \"responses\""), "codex only supports the responses wire API");
    assert!(raw.contains("requires_openai_auth = false"));
    assert!(raw.contains("experimental_bearer_token = \"ccbud-local\""));
    assert!(raw.contains("model_provider = \"ccbud\""));
    assert!(raw.contains("model = \"z-ai/glm-5.2\""));
    assert!(raw.contains("model_reasoning_effort = \"ultra\""), "thinking level defaulted to ultra");

    disconnect();
    assert!(!is_connected(4321));
    let raw = fs::read_to_string(config_path()).unwrap();
    assert!(!raw.contains("ccbud"), "our block + pointer gone: {}", raw);
    assert!(raw.contains("model = \"gpt-5\""), "prior model restored");
    assert!(!raw.contains("model_reasoning_effort"), "effort removed on disconnect (none prior)");
    assert!(raw.contains("model_provider = \"openai\""), "prior provider restored");
    assert!(raw.contains("approval_policy"), "unrelated setting still there");

    // --- case 2: no config file at all → connect creates one, disconnect leaves no ccbud ---
    let _ = fs::remove_file(config_path());
    {
        // clear the backup from case 1 so case 2 records its own (none)
        let mut c = store::read_config();
        c["codexBackup"] = Value::Null;
        store::write_config(c);
    }
    connect(8788, "tok", "m1");
    assert!(is_connected(8788));
    disconnect();
    let raw = fs::read_to_string(config_path()).unwrap_or_default();
    assert!(!raw.contains("ccbud"));

    let _ = fs::remove_dir_all(&dir);
}
