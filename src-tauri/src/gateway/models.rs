use serde_json::{json, Value};
use std::collections::HashSet;

use super::routing::{CLAUDE_TIER_MODELS, CODEX_TIER_MODELS};

// ---- /v1/models augmentation ----
fn model_entry(id: &str) -> Value {
    json!({ "type": "model", "id": id, "display_name": id, "created_at": "2025-01-01T00:00:00Z" })
}
fn alias_entries(config: &Value) -> Vec<Value> {
    let mut out = vec![];
    let mut seen = HashSet::new();
    if let Some(ps) = config.get("providers").and_then(|v| v.as_array()) {
        for p in ps {
            if let Some(ms) = p.get("models").and_then(|v| v.as_array()) {
                for m in ms {
                    if let Some(a) = m.get("alias").and_then(|v| v.as_str()) {
                        if !a.is_empty() && seen.insert(a.to_string()) {
                            out.push(model_entry(a));
                        }
                    }
                }
            }
        }
    }
    out
}
/// Default tier models for the requesting client's family (Codex → gpt tiers,
/// Claude → claude tiers).
fn tier_entries(is_codex: bool) -> Vec<Value> {
    if is_codex {
        CODEX_TIER_MODELS.iter().map(|n| model_entry(n)).collect()
    } else {
        CLAUDE_TIER_MODELS.iter().map(|n| model_entry(n)).collect()
    }
}
pub(super) fn merge_models(upstream: &Value, config: &Value, is_codex: bool) -> Value {
    let data = upstream.get("data").and_then(|d| d.as_array()).cloned().unwrap_or_default();
    let mut have: HashSet<String> = data
        .iter()
        .filter_map(|m| m.get("id").and_then(|v| v.as_str()).map(|s| s.to_string()))
        .collect();
    let mut adds = vec![];
    for a in alias_entries(config).into_iter().chain(tier_entries(is_codex)) {
        let id = a.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
        if have.insert(id) {
            adds.push(a);
        }
    }
    let mut merged = upstream.clone();
    adds.extend(data);
    merged["data"] = json!(adds);
    merged
}
pub(super) fn synthesize_models(config: &Value, is_codex: bool) -> Value {
    let mut out = alias_entries(config);
    if out.is_empty() {
        let ps = config.get("providers").and_then(|v| v.as_array()).cloned().unwrap_or_default();
        let active_id = config.get("activeProviderId").and_then(|v| v.as_str());
        let active = ps
            .iter()
            .find(|p| p.get("id").and_then(|v| v.as_str()) == active_id)
            .or_else(|| ps.first());
        let mut seen = HashSet::new();
        if let Some(a) = active {
            for k in ["defaultModel", "smallFastModel"] {
                if let Some(id) = a.get(k).and_then(|v| v.as_str()) {
                    if !id.is_empty() && seen.insert(id.to_string()) {
                        out.push(model_entry(id));
                    }
                }
            }
        }
    }
    let mut have: HashSet<String> = out
        .iter()
        .filter_map(|m| m.get("id").and_then(|v| v.as_str()).map(|s| s.to_string()))
        .collect();
    for e in tier_entries(is_codex) {
        let id = e.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
        if have.insert(id) {
            out.push(e);
        }
    }
    let first = out.first().and_then(|m| m.get("id").cloned()).unwrap_or(Value::Null);
    let last = out.last().and_then(|m| m.get("id").cloned()).unwrap_or(Value::Null);
    json!({ "data": out, "has_more": false, "first_id": first, "last_id": last })
}
