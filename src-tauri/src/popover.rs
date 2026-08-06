// Popover window wiring: the show/hide debounce timestamps, the macOS NSPanel conversion and
// the blur auto-hide hook, plus the main-window visibility hooks that drive the daily auto
// update and the tray usage title.
//
// The two setup fns are extracted verbatim from the `setup()` closure in lib.rs `run()` so both
// files stay under the split's size cap; each is called exactly once, from run()'s setup.

use tauri::Manager;

use crate::commands::auto_update_on_visible;
use crate::tray::update_tray_title;

// Timestamp (ms since epoch) of the last popover hide — used to debounce the tray click,
// which would otherwise re-show the popover on the very click that blurred it shut.
pub(crate) static LAST_POPOVER_HIDE_MS: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0);
// Timestamp of the last popover show — a fullscreen app steals focus the instant the popover
// appears, so we ignore blur within a grace window after show (else it hides before being seen).
pub(crate) static LAST_POPOVER_SHOW_MS: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0);
pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub(crate) fn setup_popover(app: &tauri::App) {
    // Popover behavior: (1) float on the current Space AND over fullscreen apps;
    // (2) auto-hide when it loses focus — clicking anywhere else closes it.
    if let Some(pop) = app.get_webview_window("popover") {
        // macOS: convert the popover into a non-activating NSPanel. Unlike a plain window,
        // a nonactivating panel can float on the CURRENT Space — including another app's
        // fullscreen Space — and shows without activating ccbud or switching Spaces.
        #[cfg(target_os = "macos")]
        {
            use tauri_nspanel::cocoa::appkit::NSWindowCollectionBehavior as CB;
            use tauri_nspanel::WebviewWindowExt as _;
            if let Ok(panel) = pop.to_panel() {
                panel.set_style_mask((1 << 7) as i32); // NSWindowStyleMaskNonactivatingPanel
                panel.set_collection_behaviour(
                    CB::NSWindowCollectionBehaviorCanJoinAllSpaces
                        | CB::NSWindowCollectionBehaviorFullScreenAuxiliary
                        | CB::NSWindowCollectionBehaviorStationary,
                );
                panel.set_floating_panel(true);
                panel.set_level(24); // ~NSMainMenuWindowLevel: above fullscreen content
                panel.set_hides_on_deactivate(false);
                panel.set_released_when_closed(false);
            }
        }
        let pop2 = pop.clone();
        pop.on_window_event(move |event| {
            // Bind + deref: `Focused(false)` as a literal pattern does NOT match against
            // &WindowEvent here (match ergonomics), so the handler would never fire.
            if let tauri::WindowEvent::Focused(focused) = event {
                if !*focused {
                    // Grace period: a fullscreen app steals focus the instant the popover
                    // shows; ignore that blur so it isn't hidden before being seen. A real
                    // click-away blur arrives well after the show.
                    if now_ms()
                        - LAST_POPOVER_SHOW_MS.load(std::sync::atomic::Ordering::Relaxed)
                        >= 400
                    {
                        let _ = pop2.hide();
                        LAST_POPOVER_HIDE_MS
                            .store(now_ms(), std::sync::atomic::Ordering::Relaxed);
                    }
                }
            }
        });
    }
}

pub(crate) fn setup_window_hooks(app: &tauri::App) {
    // Daily auto update, triggered by the app becoming visible (see auto_update_on_visible).
    // Main-window focus covers launch, tray "open main", Dock/taskbar switches and the
    // single-instance re-open; the popover-show branch of the tray click covers tray-only days.
    if let Some(main) = app.get_webview_window("main") {
        let h = app.handle().clone();
        main.on_window_event(move |event| {
            if let tauri::WindowEvent::Focused(focused) = event {
                if *focused {
                    auto_update_on_visible(&h);
                }
            }
        });
    }
    // Launch counts as today's first visibility even if no focus event fires (e.g. an
    // autostarted login launch that opens unfocused). Delayed a few seconds so the
    // network/gateway are up before the first check.
    {
        let h = app.handle().clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            let visible = h
                .get_webview_window("main")
                .and_then(|w| w.is_visible().ok())
                .unwrap_or(false);
            if visible {
                auto_update_on_visible(&h);
            }
        });
    }

    // Tray usage title: show the configured token count next to the menu-bar icon
    // (macOS), refreshed on a timer so it tracks new usage without any user action.
    {
        let h = app.handle().clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(1500));
            loop {
                update_tray_title(&h);
                std::thread::sleep(std::time::Duration::from_secs(60));
            }
        });
    }
}
