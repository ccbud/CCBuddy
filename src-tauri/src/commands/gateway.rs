// Gateway status / usage / monitor / log commands, moved verbatim from lib.rs.

use serde_json::{json, Value};

use crate::{claude, codexconnect, gateway, store, usage};

use super::config::LAST_START_ERROR;

// ---- server / usage / monitor / logs ----
pub(crate) async fn full_status(gw: &std::sync::Arc<gateway::GatewayState>) -> Value {
    let mut s = gw.status().await;
    let port = gw
        .current_port()
        .await
        .unwrap_or_else(|| store::read_config().get("port").and_then(|v| v.as_u64()).unwrap_or(8788) as u16);
    if let Some(o) = s.as_object_mut() {
        let claude_on = claude::is_connected(port);
        let codex_on = codexconnect::is_connected(port);
        // `connected` = any CLI wired to the gateway (drives the tray "已接入" indicator).
        o.insert("connected".into(), json!(claude_on || codex_on));
        o.insert("connectedClaude".into(), json!(claude_on));
        o.insert("connectedCodex".into(), json!(codex_on));
        o.insert("codexAvailable".into(), json!(codexconnect::is_available()));
        o.insert(
            "gatewayEnabled".into(),
            json!(store::read_config().get("gatewayEnabled").and_then(|v| v.as_bool()).unwrap_or(true)),
        );
        o.insert(
            "lastStartError".into(),
            LAST_START_ERROR
                .lock()
                .ok()
                .and_then(|g| g.clone())
                .map(Value::String)
                .unwrap_or(Value::Null),
        );
        o.insert("claudePath".into(), json!(claude::settings_path().to_string_lossy()));
    }
    s
}
#[tauri::command]
pub(crate) async fn server_status(
    gw: tauri::State<'_, std::sync::Arc<gateway::GatewayState>>,
) -> Result<Value, String> {
    Ok(full_status(&gw).await)
}
#[tauri::command]
pub(crate) fn usage_get(range: Option<String>) -> Value {
    let t = std::time::Instant::now();
    let cfg = store::read_config();
    // Usage surfaces (popover heatmap/stats, hero) always aggregate EVERY configured dir — the
    // conversations-page directory switcher must not silently filter the calendar down to one CLI.
    let r = usage::usage_get(&cfg, "all", range.as_deref().unwrap_or("7d"));
    eprintln!(
        "[TIMING] usage_get(range={}) {}ms",
        range.as_deref().unwrap_or("7d"),
        t.elapsed().as_millis()
    );
    r
}

/// Compact token count (mirror of usage.js `formatTokens`): 1234→"1.2K", 4.9e9→"4.9B".
pub(crate) fn format_tokens(n: i64) -> String {
    let n = n.max(0);
    if n < 1000 {
        return n.to_string();
    }
    let strip = |s: String| s.strip_suffix(".0").map(|p| p.to_string()).unwrap_or(s);
    if n < 1_000_000 {
        let v = n as f64 / 1e3;
        let s = if n < 10_000 { format!("{:.1}", v) } else { format!("{:.0}", v) };
        return format!("{}K", strip(s));
    }
    if n < 1_000_000_000 {
        let v = n as f64 / 1e6;
        let s = if n < 10_000_000 { format!("{:.1}", v) } else { format!("{:.0}", v) };
        return format!("{}M", strip(s));
    }
    let v = n as f64 / 1e9;
    format!("{}B", strip(format!("{:.1}", v)))
}
#[tauri::command]
pub(crate) async fn monitor_get(
    gw: tauri::State<'_, std::sync::Arc<gateway::GatewayState>>,
    id: Value,
) -> Result<Value, String> {
    let idn = id.as_i64().or_else(|| id.as_str().and_then(|s| s.parse().ok())).unwrap_or(-1);
    Ok(gw.monitor_get(idn).await)
}
#[tauri::command]
pub(crate) async fn monitor_clear(
    gw: tauri::State<'_, std::sync::Arc<gateway::GatewayState>>,
) -> Result<Value, String> {
    gw.monitor_clear().await;
    Ok(json!(true))
}
#[tauri::command]
pub(crate) fn logs_get(gw: tauri::State<'_, std::sync::Arc<gateway::GatewayState>>) -> Value {
    gw.logs_snapshot()
}
#[tauri::command]
pub(crate) fn logs_clear(gw: tauri::State<'_, std::sync::Arc<gateway::GatewayState>>) -> Value {
    gw.logs_clear();
    Value::Null
}
