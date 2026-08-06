// Window / app lifecycle commands, moved verbatim from lib.rs.

use serde_json::Value;
use tauri::Manager;

// ---- window / app lifecycle ----
/// macOS Dock icon follows the main window: Regular (Dock shown) while a window is open,
/// Accessory (menu-bar only) when it's closed. The popover floats over fullscreen apps via its
/// NSPanel regardless of this policy, so showing the Dock icon with the main window is safe.
pub(crate) fn set_dock_visible(app: &tauri::AppHandle, visible: bool) {
    #[cfg(target_os = "macos")]
    {
        let app2 = app.clone();
        let _ = app.run_on_main_thread(move || {
            let policy = if visible {
                tauri::ActivationPolicy::Regular
            } else {
                tauri::ActivationPolicy::Accessory
            };
            let _ = app2.set_activation_policy(policy);
        });
    }
}
#[tauri::command]
pub(crate) fn app_open_main(app: tauri::AppHandle) -> Value {
    if let Some(win) = app.get_webview_window("main") {
        set_dock_visible(&app, true);
        let _ = win.show();
        let _ = win.unminimize();
        let _ = win.set_focus();
    }
    Value::Null
}
#[tauri::command]
pub(crate) fn app_quit(app: tauri::AppHandle) -> Value {
    app.exit(0);
    Value::Null
}
#[tauri::command] pub(crate) fn window_settings_mode(on: bool) -> Value { Value::Null }
#[tauri::command]
pub(crate) fn window_view_min_width(app: tauri::AppHandle, w: i64) -> Value {
    if let Some(win) = app.get_webview_window("main") {
        let min_w = std::cmp::max(600, if w > 0 { w } else { 900 }) as f64;
        let _ = win.set_min_size(Some(tauri::Size::Logical(tauri::LogicalSize::new(min_w, 600.0))));
    }
    Value::Null
}
