// Debug self-check commands, moved verbatim from lib.rs.

use serde_json::{json, Value};
use tauri::Manager;

use crate::{exporthtml, gateway, history, store};

// ---- debug self-check (gated by CCBUD_SELFCHECK env; injected via on_page_load) ----
#[tauri::command]
pub(crate) fn selfcheck_report(report: Value) {
    let line = serde_json::to_string(&report).unwrap_or_default();
    eprintln!("[SELFCHECK] {}", line);
    // Also append to a file when CCBUD_SELFCHECK_OUT is set — a GUI-session run
    // (open .app via launchd) has no terminal-attached stderr to read.
    if let Ok(path) = std::env::var("CCBUD_SELFCHECK_OUT") {
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
            let _ = writeln!(f, "{}", line);
        }
    }
}
#[tauri::command]
pub(crate) fn selfcheck_routing() -> Value {
    gateway::routing_selftest()
}
#[tauri::command]
pub(crate) fn selfcheck_history() -> Value {
    history::history_selftest(&store::ccbud_home())
}
#[tauri::command]
pub(crate) fn selfcheck_import() -> Value {
    history::import_selftest(&store::ccbud_home())
}
#[tauri::command]
pub(crate) fn selfcheck_export() -> Value {
    let base = store::ccbud_home();
    let _ = history::history_selftest(&base);
    let file = base.join("test-claude").join("projects").join("-test-cwd").join("sess1.jsonl");
    let html = exporthtml::build_export_html(&file.to_string_lossy());
    json!({
        "len": html.len(),
        "hasConv": html.contains("__CONV__"),
        "hasContent": html.contains("hello world from selfcheck"),
        "hasSkin": html.contains("</style>"),
        "embedded": html.len() > 180000,
        "validHtml": html.starts_with("<!doctype html") && html.contains("</html>"),
    })
}
#[tauri::command]
pub(crate) fn selfcheck_popover(app: tauri::AppHandle) -> Value {
    let pop = match app.get_webview_window("popover") {
        Some(p) => p,
        None => return json!({ "err": "no popover window" }),
    };
    let mon = match pop.current_monitor() {
        Ok(Some(m)) => m,
        _ => return json!({ "err": "no monitor" }),
    };
    let scale = mon.scale_factor();
    let pw = (424.0 * scale) as i32;
    let sx = mon.position().x;
    let sy = mon.position().y;
    let sw = mon.size().width as i32;
    let sh = mon.size().height as i32;
    // Simulate a tray icon at the top-right of the menu bar, run the same placement
    // math as the real tray click, then read back where the window actually lands.
    let tray_cx = sx + sw - (12.0 * scale) as i32;
    let x = (tray_cx - pw / 2).clamp(sx + 4, sx + sw - pw - 4);
    let y = sy + (26.0 * scale) as i32;
    // macOS window ops must run on the main thread — the real tray callback already
    // does; here we hop onto it explicitly and read back inside the same closure so
    // the probe sees the post-move geometry without a cross-thread timing race.
    let (tx, rx) = std::sync::mpsc::channel();
    let pop2 = pop.clone();
    let _ = app.run_on_main_thread(move || {
        let _ = pop2.show();
        let _ = pop2.set_position(tauri::PhysicalPosition::new(x, y));
        let pos = pop2.outer_position().ok().map(|p| (p.x, p.y));
        let size = pop2.outer_size().ok().map(|s| (s.width as i32, s.height as i32));
        let _ = pop2.hide();
        let _ = tx.send((pos, size));
    });
    let (pos, size) = rx
        .recv_timeout(std::time::Duration::from_millis(1500))
        .unwrap_or((None, None));
    let in_screen = match (pos, size) {
        (Some((px, py)), Some((sw2, sh2))) => {
            px >= sx && py >= sy && (px + sw2) <= (sx + sw + 2) && (py + sh2) <= (sy + sh + 2)
        }
        _ => false,
    };
    json!({
        "scale": scale,
        "monitor": [sx, sy, sw, sh],
        "computed": [x, y],
        "popPos": pos.map(|(a, b)| json!([a, b])),
        "popSize": size.map(|(a, b)| json!([a, b])),
        "inScreen": in_screen,
    })
}
#[tauri::command]
pub(crate) async fn selfcheck_gateway(
    gw: tauri::State<'_, std::sync::Arc<gateway::GatewayState>>,
) -> Result<Value, String> {
    // Mutates config (writes a mock provider) — only ever allowed in a throwaway self-check run.
    if std::env::var("CCBUD_SELFCHECK").is_err() {
        return Err("selfcheck disabled".into());
    }
    let port = gw.current_port().await.unwrap_or(0);
    let mut r = gateway::gateway_selftest(port).await;
    let sse_ex = gw.monitor_recent().await; // last recorded by gateway_selftest = the SSE exchange
    // Exercise HEAD / (mock 404 → gateway fallback 200 → recorded) to verify monitor detail + ms.
    let head_status = reqwest::Client::new()
        .head(format!("http://127.0.0.1:{}/", port))
        .send()
        .await
        .map(|x| x.status().as_u16())
        .unwrap_or(0);
    tokio::time::sleep(std::time::Duration::from_millis(60)).await;
    let head_ex = gw.monitor_recent().await; // now the HEAD exchange
    if let Some(o) = r.as_object_mut() {
        let req_ok = sse_ex.get("reqBody").and_then(|b| b.get("text")).and_then(|t| t.as_str()).map(|s| !s.is_empty()).unwrap_or(false);
        let res_ok = sse_ex.get("resBody").and_then(|b| b.get("text")).and_then(|t| t.as_str()).map(|s| !s.is_empty()).unwrap_or(false);
        let redacted = sse_ex.get("reqHeaders").map(|h| h.to_string().contains("已隐藏")).unwrap_or(false);
        o.insert("monitorReqBody".into(), json!(req_ok));
        o.insert("monitorResBody".into(), json!(res_ok));
        o.insert("monitorRedacted".into(), json!(redacted));
        o.insert("recordHasMs".into(), json!(sse_ex.get("ms").map(|v| v.is_number()).unwrap_or(false)));
        o.insert("headStatus".into(), json!(head_status));
        o.insert(
            "headMonitored".into(),
            json!(head_ex.get("method").and_then(|m| m.as_str()) == Some("HEAD")
                && head_ex.get("reqHeaders").map(|h| h.is_object()).unwrap_or(false)
                && head_ex.get("ms").map(|v| v.is_number()).unwrap_or(false)),
        );
    }
    Ok(r)
}
