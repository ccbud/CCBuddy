// Schema normalization: merge over defaults, then sanitize every field. Moved verbatim from
// store.rs.

use serde_json::{json, Value};

use super::defaults::default_config;
use super::paths::{bool_of, collapse_home, str_of};

/// Mirror of store.js `normalize`: merge over defaults, then sanitize every field.
pub fn normalize(input: Value) -> Value {
    let mut c = default_config();
    if let Value::Object(src) = &input {
        let obj = c.as_object_mut().unwrap();
        for (k, v) in src {
            obj.insert(k.clone(), v.clone());
        }
    }

    // ---- providers ----
    let mut norm_provs: Vec<Value> = vec![];
    if let Some(Value::Array(arr)) = c.get("providers") {
        for p in arr {
            let name = {
                let n = str_of(p.get("name"));
                if n.is_empty() { "Unnamed".to_string() } else { n }
            };
            let map_default = p
                .get("mapDefaultModels")
                .map(|v| v.as_bool().unwrap_or(true))
                .unwrap_or(true);
            let mut models: Vec<Value> = vec![];
            if let Some(Value::Array(ms)) = p.get("models") {
                for m in ms {
                    let alias = str_of(m.get("alias"));
                    let upstream = str_of(m.get("upstream"));
                    if !alias.is_empty() || !upstream.is_empty() {
                        models.push(json!({ "alias": alias, "upstream": upstream }));
                    }
                }
            }
            // Upstream wire protocol. Default 'anthropic' = today's verbatim passthrough; the
            // other two make the gateway translate Claude Code's Anthropic Messages into the
            // provider's format (see src/protocol/). Anything unrecognized falls back to anthropic.
            let protocol = match p.get("protocol").and_then(|v| v.as_str()) {
                Some("openai-chat") => "openai-chat",
                Some("openai-responses") => "openai-responses",
                _ => "anthropic",
            };
            // Zhipu's Anthropic-compatible endpoint is versioned. The old preset omitted `/v1`;
            // its unversioned path returns HTTP 200 with an embedded `404 NOT_FOUND`, which cannot
            // trigger the gateway's status-based compatibility retry. Normalize only that exact
            // legacy preset URL, leaving every custom/provider URL authoritative.
            let mut base_url = str_of(p.get("baseUrl"));
            if protocol == "anthropic"
                && base_url.trim_end_matches('/') == "https://open.bigmodel.cn/api/anthropic"
            {
                base_url = "https://open.bigmodel.cn/api/anthropic/v1".to_string();
            }
            let mut np = json!({
                "id": p.get("id").cloned().unwrap_or(Value::Null),
                "name": name,
                "baseUrl": base_url,
                "authToken": str_of(p.get("authToken")),
                "defaultModel": str_of(p.get("defaultModel")),
                "smallFastModel": str_of(p.get("smallFastModel")),
                "mapDefaultModels": map_default,
                "protocol": protocol,
                "models": models,
            });
            if let Some(ic) = p.get("icon").and_then(|v| v.as_str()) {
                if !ic.trim().is_empty() {
                    np.as_object_mut()
                        .unwrap()
                        .insert("icon".into(), json!(ic.trim()));
                }
            }
            // Backend type. 'http' (default) = an ordinary upstream at baseUrl. 'plugin' = fronted
            // by a local sidecar plugin process (see plugin.rs); its baseUrl points at the plugin's
            // localhost port, maintained by PluginManager. pluginId links back to the plugin.
            let backend = match p.get("backend").and_then(|v| v.as_str()) {
                Some("plugin") => "plugin",
                _ => "http",
            };
            np.as_object_mut()
                .unwrap()
                .insert("backend".into(), json!(backend));
            if backend == "plugin" {
                np.as_object_mut()
                    .unwrap()
                    .insert("pluginId".into(), json!(str_of(p.get("pluginId"))));
            }
            norm_provs.push(np);
        }
    }
    // activeProviderId: keep if it points at a real provider, else first provider, else null.
    let active = c.get("activeProviderId").cloned().unwrap_or(Value::Null);
    let active_ok = norm_provs.iter().any(|p| p.get("id") == Some(&active));
    let active = if active_ok {
        active
    } else {
        norm_provs
            .first()
            .and_then(|p| p.get("id").cloned())
            .unwrap_or(Value::Null)
    };

    let obj = c.as_object_mut().unwrap();
    obj.insert("providers".into(), json!(norm_provs));
    obj.insert("activeProviderId".into(), active);

    // ---- scalars ----
    let port = obj
        .get("port")
        .and_then(|v| v.as_i64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
        .filter(|n| *n > 0)
        .unwrap_or(8788);
    obj.insert("port".into(), json!(port));
    obj.insert("requireToken".into(), json!(bool_of(obj.get("requireToken"), false)));
    obj.insert("gatewayEnabled".into(), json!(bool_of(obj.get("gatewayEnabled"), true)));
    obj.insert("gatewayToken".into(), json!(str_of(obj.get("gatewayToken"))));
    obj.insert("openAtLogin".into(), json!(bool_of(obj.get("openAtLogin"), false)));
    if obj.get("claudeBackup").map(|v| v.is_null()).unwrap_or(true) {
        obj.insert("claudeBackup".into(), Value::Null);
    }

    // trayUsage
    let tu = obj.get("trayUsage").cloned().unwrap_or(json!({}));
    let tu_enabled = bool_of(tu.get("enabled"), false);
    let tu_range = tu
        .get("range")
        .and_then(|v| v.as_str())
        .filter(|r| ["1d", "7d", "30d", "all"].contains(r))
        .unwrap_or("7d");
    obj.insert("trayUsage".into(), json!({ "enabled": tu_enabled, "range": tu_range }));

    // retry429 (clamped)
    let rr = obj.get("retry429").cloned().unwrap_or(json!({}));
    let rr_enabled = rr.get("enabled").map(|v| v.as_bool().unwrap_or(true)).unwrap_or(true);
    let rr_max = rr.get("max").and_then(|v| v.as_i64()).filter(|n| *n >= 0).map(|n| n.min(10)).unwrap_or(3);
    let rr_base = rr.get("baseMs").and_then(|v| v.as_i64()).filter(|n| *n >= 0).map(|n| n.min(10000)).unwrap_or(500);
    obj.insert("retry429".into(), json!({ "enabled": rr_enabled, "max": rr_max, "baseMs": rr_base }));

    obj.insert("insecureSkipVerify".into(), json!(bool_of(obj.get("insecureSkipVerify"), false)));

    // autoUpdate
    let au = obj.get("autoUpdate").cloned().unwrap_or(json!({}));
    let au_check = au.get("check").map(|v| v.as_bool().unwrap_or(true)).unwrap_or(true);
    let au_dl = au.get("autoDownload").map(|v| v.as_bool().unwrap_or(true)).unwrap_or(true);
    obj.insert("autoUpdate".into(), json!({ "check": au_check, "autoDownload": au_dl }));

    // language: only the supported set, else null
    let lang = obj
        .get("language")
        .and_then(|v| v.as_str())
        .filter(|l| ["en", "zh", "zh-TW", "ja", "ko"].contains(l))
        .map(|s| s.to_string());
    obj.insert("language".into(), lang.map(Value::String).unwrap_or(Value::Null));

    // historyDirs: trim, strip trailing slashes, dedup, ensure ~/.claude present
    let mut dirs: Vec<String> = vec![];
    if let Some(Value::Array(ds)) = obj.get("historyDirs") {
        for d in ds {
            if let Some(s) = d.as_str() {
                // Collapse home-prefixed absolute paths to `~/…` for a tidy, portable display.
                let t = collapse_home(s.trim().trim_end_matches(['/', '\\']));
                if !t.is_empty() && !dirs.iter().any(|x| *x == t) {
                    dirs.push(t);
                }
            }
        }
    }
    if !dirs.iter().any(|d| d == "~/.claude") {
        dirs.insert(0, "~/.claude".to_string());
    }
    obj.insert("historyDirs".into(), json!(dirs));

    // connectTargets: which coding CLIs are wired to the gateway. Subset of {claude, codex}, deduped.
    // Empty is a VALID state (everything disconnected) — don't snap it back to ["claude"], or the UI
    // toggle for the last-remaining CLI could never turn off. Fresh and legacy configs deliberately
    // normalize to [] so startup never mistakes a schema default for an explicit connection choice.
    let mut targets: Vec<String> = vec![];
    if let Some(arr) = obj.get("connectTargets").and_then(|v| v.as_array()) {
        for t in arr {
            if let Some(s) = t.as_str() {
                if (s == "claude" || s == "codex") && !targets.iter().any(|x| x == s) {
                    targets.push(s.to_string());
                }
            }
        }
    }
    obj.insert("connectTargets".into(), json!(targets));

    // historyActive: 'all' | '__imported__' | '__trash__' (recycle bin) | a configured dir, else 'all'.
    // '__codex__' is the retired synthetic Codex bucket — map it onto the real ~/.codex dir entry.
    let ha = obj.get("historyActive").and_then(|v| v.as_str()).unwrap_or("all").to_string();
    let ha = if ha == "__codex__" { crate::codex::codex_label() } else { ha };
    let ha_ok = ha == "all" || ha == "__imported__" || ha == "__trash__" || dirs.iter().any(|d| *d == ha);
    obj.insert("historyActive".into(), json!(if ha_ok { ha } else { "all".to_string() }));

    c
}
