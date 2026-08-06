// Reading and atomically writing config.json, plus the one provider baseUrl migration. Moved
// verbatim from store.rs.

use serde_json::{json, Value};
use std::fs;

use super::defaults::default_config;
use super::normalize::normalize;
use super::paths::{ccbud_home, config_file, config_lock, set_0600};

fn read_config_unlocked() -> Value {
    match fs::read_to_string(config_file()) {
        Ok(s) => match serde_json::from_str::<Value>(&s) {
            Ok(v) => normalize(v),
            Err(_) => default_config(),
        },
        Err(_) => default_config(),
    }
}

pub fn read_config() -> Value {
    let _guard = config_lock();
    read_config_unlocked()
}

fn write_config_unlocked(next: Value) -> (Value, bool) {
    let normalized = normalize(next);
    let dir = ccbud_home();
    if fs::create_dir_all(&dir).is_err() {
        return (normalized, false);
    }
    let file = config_file();
    let tmp = dir.join("config.json.tmp");
    if let Ok(bytes) = serde_json::to_vec_pretty(&normalized) {
        if fs::write(&tmp, &bytes).is_ok() {
            set_0600(&tmp);
            if fs::rename(&tmp, &file).is_ok() {
                set_0600(&file);
                return (normalized, true);
            }
        }
    }
    let _ = fs::remove_file(tmp);
    (normalized, false)
}

pub fn write_config(next: Value) -> Value {
    let _guard = config_lock();
    write_config_unlocked(next).0
}

pub(super) fn update_provider_base_url_to_v1(
    config: &mut Value,
    provider_id: &str,
    expected_base_url: &str,
) -> bool {
    let Some(provider) = config
        .get_mut("providers")
        .and_then(Value::as_array_mut)
        .and_then(|providers| {
            providers
                .iter_mut()
                .find(|provider| provider.get("id").and_then(Value::as_str) == Some(provider_id))
        })
    else {
        return false;
    };
    if provider.get("backend").and_then(Value::as_str) == Some("plugin")
        || provider.get("baseUrl").and_then(Value::as_str) != Some(expected_base_url)
    {
        return false;
    }
    let Some(provider) = provider.as_object_mut() else {
        return false;
    };
    provider.insert(
        "baseUrl".into(),
        json!(format!("{}/v1", expected_base_url.trim_end_matches('/'))),
    );
    true
}

/// Atomically migrate one HTTP provider's base URL after a successful `/v1` fallback.
/// The expected URL is a compare-and-swap guard against overwriting a concurrent user edit.
pub fn migrate_provider_base_url_to_v1(
    provider_id: &str,
    expected_base_url: &str,
) -> Option<Value> {
    let _guard = config_lock();
    let mut config = read_config_unlocked();
    if !update_provider_base_url_to_v1(&mut config, provider_id, expected_base_url) {
        return None;
    }
    let (saved, persisted) = write_config_unlocked(config);
    persisted.then_some(saved)
}
