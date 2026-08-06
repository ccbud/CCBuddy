// Config + provider CRUD commands, moved verbatim from lib.rs.

use serde_json::{json, Value};
use tauri::Emitter;

use crate::tray::update_tray_title;
use crate::{claude, codexconnect, gateway, store, usage};

use super::connect::codex_model;
use super::gateway::full_status;
use super::plugins::PluginState;

// ---- config / providers (real, store.rs) ----
#[tauri::command]
pub(crate) fn config_get() -> Value {
    store::read_config()
}
/// Last gateway start error (e.g. a bad port the user typed). Surfaced via server:status so the
/// renderer can show the failure banner. Mirrors main.js lastStartError.
pub(super) static LAST_START_ERROR: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
#[tauri::command]
pub(crate) async fn config_save(
    app: tauri::AppHandle,
    gw: tauri::State<'_, std::sync::Arc<gateway::GatewayState>>,
    cfg: Value,
) -> Result<Value, String> {
    let prev = store::read_config();
    let prev_port = prev.get("port").and_then(|v| v.as_u64()).unwrap_or(8788) as u16;
    let next_port = cfg
        .get("port")
        .and_then(|v| v.as_u64())
        .map(|p| p as u16)
        .unwrap_or(prev_port);
    let was_connected = claude::is_connected(prev_port);
    let codex_was_connected = codexconnect::is_connected(prev_port);
    let prev_dirs = prev.get("historyDirs").cloned();

    // If the gateway is running and the port changed, bind the NEW port BEFORE committing so a bad
    // port can never lock the user out — roll back to the old port and report on failure.
    if next_port != prev_port && gw.current_port().await.is_some() {
        gw.stop().await;
        if let Err(e) = gw.start(next_port).await {
            let _ = gw.start(prev_port).await;
            let msg = format!("端口 {} 启动失败：{}", next_port, e);
            *LAST_START_ERROR.lock().unwrap() = Some(msg.clone());
            gw.emit("gateway:status", full_status(&gw).await);
            return Err(msg);
        }
        *LAST_START_ERROR.lock().unwrap() = None;
    }

    let saved = store::write_config(cfg);
    use tauri_plugin_autostart::ManagerExt;
    let want = saved.get("openAtLogin").and_then(|v| v.as_bool()).unwrap_or(false);
    let mgr = app.autolaunch();
    let _ = if want { mgr.enable() } else { mgr.disable() };

    // Keep each connected CLI's config in sync if connected (port/token may have changed).
    if was_connected || codex_was_connected {
        let port = saved.get("port").and_then(|v| v.as_u64()).unwrap_or(8788) as u16;
        let token = claude::current_token(&saved);
        if was_connected {
            claude::connect(port, &token);
        }
        if codex_was_connected {
            codexconnect::connect(port, &token, &codex_model(&saved));
        }
    }

    // History dirs changed → invalidate + re-warm the usage cache and notify the renderer.
    if saved.get("historyDirs").cloned() != prev_dirs {
        usage::invalidate_cache();
        let cfg2 = saved.clone();
        std::thread::spawn(move || usage::warm_cache(&cfg2, "all"));
        let _ = app.emit("history:changed", json!({ "files": [] }));
    }

    update_tray_title(&app);
    gw.emit("gateway:status", full_status(&gw).await);
    Ok(saved)
}
#[tauri::command]
pub(crate) fn provider_upsert(p: Value) -> Value {
    let mut cfg = store::read_config();
    let mut provider = p;
    let pid = provider.get("id").and_then(|v| v.as_str()).map(|s| s.to_string());
    {
        let provs = cfg["providers"].as_array_mut().unwrap();
        match pid {
            Some(id) if !id.is_empty() => {
                if let Some(i) = provs
                    .iter()
                    .position(|x| x.get("id").and_then(|v| v.as_str()) == Some(id.as_str()))
                {
                    provs[i] = provider;
                } else {
                    provs.push(provider);
                }
            }
            _ => {
                let id = store::gen_id();
                provider
                    .as_object_mut()
                    .unwrap()
                    .insert("id".into(), json!(id.clone()));
                provs.push(provider);
                if cfg["activeProviderId"].is_null() {
                    cfg["activeProviderId"] = json!(id);
                }
            }
        }
    }
    store::write_config(cfg)
}
#[tauri::command]
pub(crate) fn provider_delete(id: String) -> Value {
    let mut cfg = store::read_config();
    let kept: Vec<Value> = cfg["providers"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|p| p.get("id").and_then(|v| v.as_str()) != Some(id.as_str()))
                .cloned()
                .collect()
        })
        .unwrap_or_default();
    cfg["providers"] = json!(kept);
    if cfg["activeProviderId"].as_str() == Some(id.as_str()) {
        cfg["activeProviderId"] = cfg["providers"]
            .as_array()
            .and_then(|a| a.first())
            .and_then(|p| p.get("id").cloned())
            .unwrap_or(Value::Null);
    }
    store::write_config(cfg)
}
#[tauri::command]
pub(crate) fn provider_set_active(pm: PluginState<'_>, id: String) -> Result<Value, String> {
    let cfg = store::read_config();
    // A plugin-backed service can only be activated while its plugin is running —
    // otherwise the gateway would forward to a dead port. The UI localizes this code.
    if let Some(p) = cfg
        .get("providers")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.iter().find(|p| p.get("id").and_then(|v| v.as_str()) == Some(id.as_str())))
    {
        if p.get("backend").and_then(|v| v.as_str()) == Some("plugin") {
            let plugin_id = p.get("pluginId").and_then(|v| v.as_str()).unwrap_or("");
            if !pm.is_running(plugin_id) {
                return Err("pluginNotRunning".into());
            }
        }
    }
    let mut cfg = store::read_config();
    cfg["activeProviderId"] = json!(id);
    Ok(store::write_config(cfg))
}
