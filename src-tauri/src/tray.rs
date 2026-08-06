// System tray title + dynamic, localized context menu, moved verbatim from lib.rs.

use serde_json::{json, Value};
use tauri::Manager;

use crate::commands::format_tokens;
use crate::{gateway, store, usage};

/// Set the macOS menu-bar tray title to the configured usage token count (or clear it when
/// trayUsage is off). Heavy work (config read + usage scan) runs on the caller's thread;
/// only the set_title call hops to the main thread, where macOS requires UI mutation.
pub(crate) fn update_tray_title(app: &tauri::AppHandle) {
    let config = store::read_config();
    let tu = config.get("trayUsage").cloned().unwrap_or_else(|| json!({}));
    let enabled = tu.get("enabled").and_then(|v| v.as_bool()).unwrap_or(false);
    let title: Option<String> = if enabled {
        let range = tu.get("range").and_then(|v| v.as_str()).unwrap_or("7d").to_string();
        // Same global scope as the popover — the tray count is a whole-machine number.
        let tokens = usage::usage_get(&config, "all", &range)
            .get("tokens")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        Some(format!(" {}", format_tokens(tokens)))
    } else {
        None
    };
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(tray) = app2.tray_by_id("main") {
            let _ = tray.set_title(title.as_deref());
        }
    });
}

// ---- system tray: dynamic, localized context menu (parity with main.js buildTrayMenu) ----
struct TrayLabels {
    running_with: &'static str,
    stopped: &'static str,
    open_main: &'static str,
    stop_gw: &'static str,
    start_gw: &'static str,
    quit: &'static str,
    check_updates: &'static str,
}
fn tray_labels(lang: &str) -> TrayLabels {
    match lang {
        // config.language stores "zh" (store.rs normalize) — accept both spellings.
        "zh" | "zh-CN" => TrayLabels { running_with: "● 网关运行中 · {name}", stopped: "○ 网关已停止", open_main: "打开主界面", stop_gw: "停止网关服务", start_gw: "启动网关服务", quit: "退出 CC Buddy", check_updates: "检查更新…" },
        "zh-TW" => TrayLabels { running_with: "● 閘道執行中 · {name}", stopped: "○ 閘道已停止", open_main: "開啟主視窗", stop_gw: "停止閘道服務", start_gw: "啟動閘道服務", quit: "結束 CC Buddy", check_updates: "檢查更新…" },
        "ja" => TrayLabels { running_with: "● ゲートウェイ稼働中 · {name}", stopped: "○ ゲートウェイ停止中", open_main: "メインウィンドウを開く", stop_gw: "ゲートウェイを停止", start_gw: "ゲートウェイを起動", quit: "CC Buddy を終了", check_updates: "更新を確認…" },
        "ko" => TrayLabels { running_with: "● 게이트웨이 실행 중 · {name}", stopped: "○ 게이트웨이 중지됨", open_main: "메인 창 열기", stop_gw: "게이트웨이 중지", start_gw: "게이트웨이 시작", quit: "CC Buddy 종료", check_updates: "업데이트 확인…" },
        _ => TrayLabels { running_with: "● Gateway running · {name}", stopped: "○ Gateway stopped", open_main: "Open main window", stop_gw: "Stop gateway service", start_gw: "Start gateway service", quit: "Quit CC Buddy", check_updates: "Check for updates…" },
    }
}
pub(crate) fn config_lang(config: &Value) -> String {
    config.get("language").and_then(|v| v.as_str()).unwrap_or("en").to_string()
}
fn active_provider_name(config: &Value) -> String {
    let id = match config.get("activeProviderId").and_then(|v| v.as_str()) {
        Some(i) => i,
        None => return String::new(),
    };
    config
        .get("providers")
        .and_then(|v| v.as_array())
        .and_then(|arr| {
            arr.iter()
                .find(|p| p.get("id").and_then(|v| v.as_str()) == Some(id))
                .and_then(|p| p.get("name").and_then(|v| v.as_str()))
        })
        .unwrap_or("")
        .to_string()
}
pub(crate) fn build_tray_menu(
    app: &tauri::AppHandle,
    running: bool,
    provider: &str,
    lang: &str,
) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
    let l = tray_labels(lang);
    let status_txt = if running {
        let name = if provider.is_empty() { "CC Buddy" } else { provider };
        l.running_with.replace("{name}", name)
    } else {
        l.stopped.to_string()
    };
    // Status row is disabled (it's an indicator, like main.js { enabled: false }).
    let status_i = MenuItem::with_id(app, "tray_status", status_txt, false, None::<&str>)?;
    let open_i = MenuItem::with_id(app, "tray_open", l.open_main, true, None::<&str>)?;
    let conn_i = if running {
        MenuItem::with_id(app, "tray_gw_stop", l.stop_gw, true, None::<&str>)?
    } else {
        MenuItem::with_id(app, "tray_gw_start", l.start_gw, true, None::<&str>)?
    };
    let check_i = MenuItem::with_id(app, "tray_check", l.check_updates, true, None::<&str>)?;
    let quit_i = MenuItem::with_id(app, "tray_quit", l.quit, true, None::<&str>)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    Menu::with_items(app, &[&status_i, &sep1, &open_i, &conn_i, &check_i, &sep2, &quit_i])
}
/// Rebuild the tray menu to reflect the gateway service state + locale + active provider.
pub(crate) fn refresh_tray_menu(app: &tauri::AppHandle) {
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        let config = store::read_config();
        let running = app2
            .try_state::<std::sync::Arc<gateway::GatewayState>>()
            .map(|s| s.port_sync().is_some())
            .unwrap_or(false);
        let provider = active_provider_name(&config);
        let lang = config_lang(&config);
        if let Ok(menu) = build_tray_menu(&app2, running, &provider, &lang) {
            if let Some(tray) = app2.tray_by_id("main") {
                let _ = tray.set_menu(Some(menu));
            }
        }
    });
}
