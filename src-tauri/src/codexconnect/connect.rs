// Connect / disconnect: inject (and later remove) the `[model_providers.ccbud]` block and the
// model/model_provider pointers, backing the user's prior values up into config.codexBackup once.

use super::config::{gateway_base, read_doc, write_doc, PROVIDER_ID};
use crate::store;
use serde_json::{json, Value};
use toml_edit::{value, Item, Table};

pub fn is_connected(port: u16) -> bool {
    let doc = read_doc();
    doc.get("model_providers")
        .and_then(|mp| mp.as_table())
        .and_then(|t| t.get(PROVIDER_ID))
        .and_then(|p| p.as_table())
        .and_then(|t| t.get("base_url"))
        .and_then(|b| b.as_str())
        .map(|b| b == gateway_base(port))
        .unwrap_or(false)
}

/// Connect Codex to the gateway. `model` is the model Codex will request (routed by the gateway);
/// `token` is the bearer written inline (a local placeholder unless the gateway enforces a token).
pub fn connect(port: u16, token: &str, model: &str) {
    let mut doc = read_doc();

    // Back up the user's prior model/model_provider exactly once (before we overwrite them).
    let cfg = store::read_config();
    if cfg.get("codexBackup").map(|v| v.is_null()).unwrap_or(true) {
        let prior_model = doc.get("model").and_then(|v| v.as_str()).map(|s| s.to_string());
        let prior_provider = doc.get("model_provider").and_then(|v| v.as_str()).map(|s| s.to_string());
        let prior_effort = doc.get("model_reasoning_effort").and_then(|v| v.as_str()).map(|s| s.to_string());
        let backup = json!({
            "model": prior_model.map(Value::String).unwrap_or(Value::Null),
            "model_provider": prior_provider.map(Value::String).unwrap_or(Value::Null),
            "model_reasoning_effort": prior_effort.map(Value::String).unwrap_or(Value::Null),
        });
        let mut next = cfg.clone();
        next["codexBackup"] = backup;
        store::write_config(next);
    }

    // Point Codex at our provider.
    doc["model_provider"] = value(PROVIDER_ID);
    if !model.is_empty() {
        doc["model"] = value(model);
    }
    // Default the thinking level to ultra; the gateway/plugin clamps it to what the
    // active provider actually supports (e.g. grok caps at "high").
    doc["model_reasoning_effort"] = value("ultra");

    // Ensure [model_providers] exists as a real table, then set our block.
    if !doc.contains_key("model_providers") {
        doc["model_providers"] = Item::Table(Table::new());
    }
    let mut block = Table::new();
    block.insert("name", value("CC Buddy"));
    block.insert("base_url", value(gateway_base(port)));
    block.insert("wire_api", value("responses"));
    block.insert("requires_openai_auth", value(false));
    block.insert("experimental_bearer_token", value(token));
    if let Some(mp) = doc["model_providers"].as_table_mut() {
        mp.insert(PROVIDER_ID, Item::Table(block));
    }

    let _ = write_doc(&doc);
}

/// Disconnect Codex: restore the backed-up model/model_provider and remove our provider block.
pub fn disconnect() {
    let cfg = store::read_config();
    let backup = cfg.get("codexBackup").cloned().unwrap_or(Value::Null);
    let mut doc = read_doc();

    // Remove our provider block.
    if let Some(mp) = doc.get_mut("model_providers").and_then(|v| v.as_table_mut()) {
        mp.remove(PROVIDER_ID);
        // Drop the whole table if it's now empty so we don't leave `[model_providers]` dangling.
        if mp.is_empty() {
            doc.as_table_mut().remove("model_providers");
        }
    }

    if backup.is_object() {
        match backup.get("model_provider").cloned().unwrap_or(Value::Null) {
            Value::String(s) => doc["model_provider"] = value(s),
            _ => {
                doc.as_table_mut().remove("model_provider");
            }
        }
        match backup.get("model").cloned().unwrap_or(Value::Null) {
            Value::String(s) => doc["model"] = value(s),
            _ => {
                doc.as_table_mut().remove("model");
            }
        }
        match backup.get("model_reasoning_effort").cloned().unwrap_or(Value::Null) {
            Value::String(s) => doc["model_reasoning_effort"] = value(s),
            _ => {
                doc.as_table_mut().remove("model_reasoning_effort");
            }
        }
        let mut next = cfg.clone();
        next["codexBackup"] = Value::Null;
        store::write_config(next);
    } else {
        // No backup (connected out-of-band): just drop the pointer we would have set.
        if doc.get("model_provider").and_then(|v| v.as_str()) == Some(PROVIDER_ID) {
            doc.as_table_mut().remove("model_provider");
        }
    }

    let _ = write_doc(&doc);
}
