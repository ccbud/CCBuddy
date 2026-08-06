// System tray icon construction and its menu / click event handlers.
//
// Extracted verbatim from the `setup()` closure in lib.rs `run()` (the block that built the
// TrayIconBuilder) so both files stay under the split's size cap. Called exactly once, from
// run()'s setup, with the same `app` and `startup_cfg` it closed over there.

use serde_json::{json, Value};
use tauri::{Emitter, Manager};

use crate::commands::{auto_update_on_visible, full_status, set_dock_visible};
use crate::popover::{now_ms, LAST_POPOVER_HIDE_MS, LAST_POPOVER_SHOW_MS};
use crate::tray::{build_tray_menu, config_lang, refresh_tray_menu};
use crate::{gateway, store};

// System tray: icon + dynamic i18n menu (status / open / connect-or-disconnect /
// check-updates / quit, parity with main.js buildTrayMenu) + click-to-open popover.
pub(crate) fn install_tray(app: &tauri::App, startup_cfg: &Value) -> tauri::Result<()> {
    use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
    let menu = build_tray_menu(app.handle(), false, "", &config_lang(&startup_cfg))?;
    // Menu-bar icon: monochrome template (like other macOS apps), auto black/white.
    let tray_img = tauri::image::Image::from_bytes(include_bytes!("../../build/iconTemplate.png"))
        .unwrap_or_else(|_| app.default_window_icon().cloned().unwrap());
    let _ = TrayIconBuilder::with_id("main")
        .icon(tray_img)
        .icon_as_template(true)
        .tooltip("CC Buddy")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "tray_open" => {
                if let Some(w) = app.get_webview_window("main") {
                    set_dock_visible(app, true);
                    let _ = w.show();
                    let _ = w.unminimize();
                    let _ = w.set_focus();
                }
            }
            // Tray toggles the gateway SERVICE (start/stop), never the CLI configs.
            "tray_gw_start" | "tray_gw_stop" => {
                let on = event.id.as_ref() == "tray_gw_start";
                let app = app.clone();
                tauri::async_runtime::spawn(async move {
                    let mut cfg = store::read_config();
                    cfg["gatewayEnabled"] = json!(on);
                    let saved = store::write_config(cfg);
                    let port = saved.get("port").and_then(|v| v.as_u64()).unwrap_or(8788) as u16;
                    let gw = app
                        .try_state::<std::sync::Arc<gateway::GatewayState>>()
                        .map(|s| s.inner().clone());
                    if let Some(gw) = gw {
                        if on {
                            let _ = gw.start(port).await;
                        } else {
                            gw.stop().await;
                        }
                        let status = full_status(&gw).await;
                        gw.emit("gateway:status", status);
                    }
                    refresh_tray_menu(&app);
                });
            }
            "tray_check" => {
                if let Some(w) = app.get_webview_window("main") {
                    set_dock_visible(app, true);
                    let _ = w.show();
                    let _ = w.unminimize();
                    let _ = w.set_focus();
                }
                // Open the About/update pane shortly after the window is up (main.js parity).
                let app2 = app.clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                    let _ = app2.emit("update:openPane", json!({}));
                });
            }
            "tray_quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                rect,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Some(pop) = app.get_webview_window("popover") {
                    #[cfg(target_os = "macos")]
                    let vis_before = {
                        use tauri_nspanel::ManagerExt as _;
                        app.get_webview_panel("popover")
                            .map(|p| p.is_visible())
                            .unwrap_or(false)
                    };
                    #[cfg(not(target_os = "macos"))]
                    let vis_before = pop.is_visible().unwrap_or(false);
                    let debounced = now_ms()
                        - LAST_POPOVER_HIDE_MS
                            .load(std::sync::atomic::Ordering::Relaxed)
                        < 250;
                    let action;
                    if vis_before {
                        #[cfg(target_os = "macos")]
                        {
                            use tauri_nspanel::ManagerExt as _;
                            if let Ok(p) = app.get_webview_panel("popover") {
                                p.order_out(None);
                            }
                        }
                        #[cfg(not(target_os = "macos"))]
                        let _ = pop.hide();
                        LAST_POPOVER_HIDE_MS
                            .store(now_ms(), std::sync::atomic::Ordering::Relaxed);
                        action = "hide";
                    } else if debounced {
                        // Debounce: clicking the tray first blurs (hides) the popover;
                        // without this the same click would re-show it instantly.
                        action = "debounce_skip";
                    } else {
                        // Center under the tray icon, clamped to the monitor (rect +
                        // scale are physical px, so retina is handled correctly).
                        //
                        // Pick the monitor the TRAY icon sits on. pop.current_monitor() is the
                        // monitor the (hidden) popover window last sat on, which on a
                        // multi-display setup is often NOT the screen whose menu bar was
                        // clicked; using it clamps the popover to the wrong monitor's
                        // bounds. Find the monitor whose physical bounds contain the tray
                        // rect (each candidate's own scale converts the rect to px).
                        let mon = pop
                            .available_monitors()
                            .ok()
                            .and_then(|mons| {
                                mons.into_iter().find(|m| {
                                    let p = rect
                                        .position
                                        .to_physical::<f64>(m.scale_factor());
                                    let mp = m.position();
                                    let ms = m.size();
                                    p.x >= mp.x as f64
                                        && p.x < mp.x as f64 + ms.width as f64
                                        && p.y >= mp.y as f64
                                        && p.y < mp.y as f64 + ms.height as f64
                                })
                            })
                            .or_else(|| pop.current_monitor().ok().flatten())
                            .or_else(|| pop.primary_monitor().ok().flatten());
                        let geom = mon.map(|mon| {
                            let scale = mon.scale_factor();
                            let pw = (424.0 * scale) as i32;
                            let sx = mon.position().x;
                            let sw = mon.size().width as i32;
                            let tray_pos = rect.position.to_physical::<f64>(scale);
                            let tray_size = rect.size.to_physical::<f64>(scale);
                            let tray_cx = (tray_pos.x + tray_size.width / 2.0) as i32;
                            let x = (tray_cx - pw / 2).clamp(sx + 4, sx + sw - pw - 4);
                            let y = (tray_pos.y + tray_size.height + 2.0) as i32;
                            tauri::PhysicalPosition::new(x, y)
                        });
                        if let Some(p) = geom {
                            let _ = pop.set_position(p);
                        }
                        // Show via the NSPanel: nonactivating, so it appears on the
                        // CURRENT Space (incl. a fullscreen app's) without activating
                        // ccbud or switching Spaces.
                        #[cfg(target_os = "macos")]
                        {
                            use tauri_nspanel::ManagerExt as _;
                            if let Ok(p) = app.get_webview_panel("popover") {
                                p.show();
                            }
                        }
                        #[cfg(not(target_os = "macos"))]
                        {
                            let _ = pop.show();
                            let _ = pop.set_focus();
                        }
                        if let Some(p) = geom {
                            let _ = pop.set_position(p);
                        }
                        let _ = app.emit("popover:show", ());
                        LAST_POPOVER_SHOW_MS
                            .store(now_ms(), std::sync::atomic::Ordering::Relaxed);
                        // The popover appearing counts as "app became visible today".
                        auto_update_on_visible(app);
                        action = "show";
                    }
                    if let Ok(path) = std::env::var("CCBUD_SELFCHECK_OUT") {
                        use std::io::Write;
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .create(true)
                            .append(true)
                            .open(&path)
                        {
                            let _ = writeln!(
                                f,
                                "{}",
                                json!({ "trayClick": action, "visBefore": vis_before })
                            );
                        }
                    }
                }
            }
        })
        .build(app)?;
    Ok(())
}
