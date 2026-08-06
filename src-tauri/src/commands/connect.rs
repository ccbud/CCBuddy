// Coding-CLI connect/disconnect commands and the connectTargets helpers, moved verbatim
// from lib.rs.

use serde_json::{json, Value};

use crate::tray::refresh_tray_menu;
use crate::{claude, codexconnect, gateway, store};

use super::config::LAST_START_ERROR;
use super::gateway::full_status;

// ---- coding CLI connect / replay ----
/// The literal selected CLIs from config `connectTargets` (subset of {claude, codex}, deduped).
/// Empty is a valid state ("nothing connected") — the hero Connect button substitutes a default.
fn connect_targets(cfg: &Value) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    if let Some(a) = cfg.get("connectTargets").and_then(|v| v.as_array()) {
        for v in a {
            if let Some(s) = v.as_str() {
                if (s == "claude" || s == "codex") && !out.iter().any(|x| x == s) {
                    out.push(s.to_string());
                }
            }
        }
    }
    out
}

/// Plan the safe subset of connections to repair on startup. Older releases could persist the
/// then-default `["claude"]` without the user ever connecting, so selection alone is insufficient:
/// a target's compatibility backup is the proof that CC Buddy previously took ownership of it.
pub(crate) fn startup_reconcile_targets(cfg: &Value) -> Vec<String> {
    connect_targets(cfg)
        .into_iter()
        .filter(|target| {
            let backup_key = if target == "claude" {
                "claudeBackup"
            } else {
                "codexBackup"
            };
            cfg.get(backup_key).map(Value::is_object).unwrap_or(false)
        })
        .collect()
}

/// Repair only previously managed, still-selected targets. This intentionally has no disconnect
/// branch: startup must not restore/consume an unselected target's compatibility backup. Since each
/// connect call is gated on an existing object backup, it also cannot create a first-time backup.
pub(crate) fn reconcile_connections_on_startup(cfg: &Value) {
    let selected = startup_reconcile_targets(cfg);
    if selected.is_empty() {
        return;
    }
    let port = cfg.get("port").and_then(|v| v.as_u64()).unwrap_or(8788) as u16;
    let token = claude::current_token(cfg);
    if selected.iter().any(|target| target == "claude") {
        claude::connect(port, &token);
    }
    if selected.iter().any(|target| target == "codex") {
        codexconnect::connect(port, &token, &codex_model(cfg));
    }
}

/// The legacy one-click Connect command still has a useful default even though startup does not:
/// when no target is selected, choose Claude and persist that now-explicit selection.
pub(crate) fn ensure_hero_connect_target(cfg: &mut Value) -> bool {
    if connect_targets(cfg).is_empty() {
        cfg["connectTargets"] = json!(["claude"]);
        true
    } else {
        false
    }
}

/// The model written into Codex's config. `gpt-5.4` is a stable model identity understood by the
/// current CLI and enables its normal function/custom tool registry for custom providers. The
/// synthetic `gpt-5.6-sol-pro` identity previously used here selected code-mode metadata and made
/// Codex send an empty Responses `tools` array, so the gateway could never drive an agent turn.
pub(super) fn codex_model(_cfg: &Value) -> String {
    "gpt-5.4".to_string()
}

/// Make each CLI's config file match the selected `connectTargets`: write the selected ones to
/// point at the gateway, restore the rest. PURELY a config-file operation — the gateway service
/// itself is an independent switch (`gatewayEnabled`), never started or stopped from here.
fn apply_connections(cfg: &Value) {
    let selected = connect_targets(cfg);
    let claude_on = selected.iter().any(|t| t == "claude");
    let codex_on = selected.iter().any(|t| t == "codex");
    let port = cfg.get("port").and_then(|v| v.as_u64()).unwrap_or(8788) as u16;
    let token = claude::current_token(cfg);
    if claude_on {
        claude::connect(port, &token);
    } else {
        claude::disconnect();
    }
    if codex_on {
        codexconnect::connect(port, &token, &codex_model(cfg));
    } else {
        codexconnect::disconnect();
    }
}

#[tauri::command]
pub(crate) async fn claude_connect(
    app: tauri::AppHandle,
    gw: tauri::State<'_, std::sync::Arc<gateway::GatewayState>>,
) -> Result<Value, String> {
    let mut cfg = store::read_config();
    let n = cfg.get("providers").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0);
    if n == 0 {
        return Ok(json!({ "ok": false, "reason": "noProvider" }));
    }
    // Hero "一键接入" with nothing selected connects Claude Code by default (and persists it, so the
    // toggle reflects it).
    if ensure_hero_connect_target(&mut cfg) {
        cfg = store::write_config(cfg);
    }
    apply_connections(&cfg);
    let status = full_status(&gw).await;
    gw.emit("gateway:status", status);
    refresh_tray_menu(&app);
    Ok(json!({ "ok": true }))
}
#[tauri::command]
pub(crate) async fn claude_disconnect(
    app: tauri::AppHandle,
    gw: tauri::State<'_, std::sync::Arc<gateway::GatewayState>>,
) -> Result<Value, String> {
    // Master off: restore BOTH CLIs' config files (idempotent). The gateway service keeps its own
    // switch — removing the CLI wiring doesn't stop it.
    claude::disconnect();
    codexconnect::disconnect();
    let status = full_status(&gw).await;
    gw.emit("gateway:status", status);
    refresh_tray_menu(&app);
    Ok(json!({ "ok": true }))
}

/// Independent gateway-service switch: persist `gatewayEnabled` and start/stop the localhost
/// server. CLI config files are untouched — connect/disconnect is a separate, config-only action.
#[tauri::command]
pub(crate) async fn gateway_set_enabled(
    app: tauri::AppHandle,
    gw: tauri::State<'_, std::sync::Arc<gateway::GatewayState>>,
    on: bool,
) -> Result<Value, String> {
    let mut cfg = store::read_config();
    cfg["gatewayEnabled"] = json!(on);
    let saved = store::write_config(cfg);
    if on {
        let port = saved.get("port").and_then(|v| v.as_u64()).unwrap_or(8788) as u16;
        if let Err(e) = gw.start(port).await {
            let msg = format!("port {} failed: {}", port, e);
            *LAST_START_ERROR.lock().unwrap() = Some(msg.clone());
            gw.emit("gateway:status", full_status(&gw).await);
            refresh_tray_menu(&app);
            return Ok(json!({ "ok": false, "reason": "portFailed", "message": msg }));
        }
        *LAST_START_ERROR.lock().unwrap() = None;
    } else {
        gw.stop().await;
    }
    let status = full_status(&gw).await;
    gw.emit("gateway:status", status);
    refresh_tray_menu(&app);
    Ok(json!({ "ok": true }))
}

/// Live per-CLI switch: flip one target on/off, persist the selection, and immediately write or
/// restore that CLI's config file. Config-only — the gateway service has its own switch.
#[tauri::command]
pub(crate) async fn set_connect_target(
    app: tauri::AppHandle,
    gw: tauri::State<'_, std::sync::Arc<gateway::GatewayState>>,
    target: String,
    on: bool,
) -> Result<Value, String> {
    let mut cfg = store::read_config();
    if on && cfg.get("providers").and_then(|v| v.as_array()).map(|a| a.is_empty()).unwrap_or(true) {
        return Ok(json!({ "ok": false, "reason": "noProvider" }));
    }
    let mut targets = connect_targets(&cfg);
    targets.retain(|t| t != &target);
    if on && (target == "claude" || target == "codex") {
        targets.push(target.clone());
    }
    cfg["connectTargets"] = json!(targets);
    let saved = store::write_config(cfg);
    apply_connections(&saved);
    let status = full_status(&gw).await;
    gw.emit("gateway:status", status);
    refresh_tray_menu(&app);
    Ok(json!({ "ok": true }))
}
