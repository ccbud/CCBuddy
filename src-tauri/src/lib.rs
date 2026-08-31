// ccbud Tauri backend.
//
// Registers the IPC surface consumed by the shared renderer and wires the native runtime:
// config persistence, localhost gateway, Claude integrations, history/usage/export, tray,
// popover, updater, and self-check hooks.
#![allow(unused_variables)]

mod antigravity;
mod claude;
mod codex;
mod codexconnect;
mod commands;
mod copilot;
mod counttokens;
mod exporthtml;
mod gateway;
mod grok;
mod history;
mod legacybundle;
mod plugin;
mod popover;
mod protocol;
mod qoder;
mod sidecar;
mod skills;
mod startup;
mod store;
mod tray;
mod trayicon;
mod usage;
mod ziputil;

use tauri::Manager;

// Every #[tauri::command] lives in a topic module under commands/; re-exported here so
// generate_handler! below can keep naming them unqualified, and so the paths other modules
// already use (crate::refresh_tray_menu, crate::update_tray_title, …) keep resolving.
pub(crate) use commands::*;
pub(crate) use tray::{refresh_tray_menu, update_tray_title};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Must run before the builder: it may rename the bundle and hand off to a
    // fresh instance at the new path.
    #[cfg(target_os = "macos")]
    startup::migrate_legacy_bundle_name();

    #[allow(unused_mut)]
    let mut builder = tauri::Builder::default()
        // single-instance MUST be the first plugin registered.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.show();
                let _ = w.unminimize();
                let _ = w.set_focus();
            }
        }))
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_updater::Builder::new().build());
    // macOS: NSPanel plugin so the popover can be a non-activating panel that floats over
    // fullscreen apps (a plain window can't reliably appear on another app's fullscreen Space).
    #[cfg(target_os = "macos")]
    {
        builder = builder.plugin(tauri_nspanel::init());
    }
    builder
        .on_page_load(|webview, payload| {
            if matches!(payload.event(), tauri::webview::PageLoadEvent::Finished)
                && std::env::var("CCBUD_SELFCHECK").is_ok()
            {
                match webview.label() {
                    "main" => {
                        let _ = webview.eval(SELFCHECK_JS);
                    }
                    "popover" => {
                        let _ = webview.eval(POPOVER_SELFCHECK_JS);
                    }
                    _ => {}
                }
            }
        })
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }
            // Gateway + plugin manager are managed immediately so the IPC surface is live the
            // moment the webview loads. Every filesystem-heavy boot step (one-time migrations,
            // plugin reconcile, CLI connection repair, gateway/plugin start, history watcher
            // registration, usage-cache warm) runs off the main thread — see
            // startup::spawn_background_boot — so the window paints and responds instantly.
            let gw = gateway::GatewayState::new(app.handle().clone());
            app.manage(gw.clone());
            let pm = plugin::PluginManager::new();
            app.manage(pm.clone());
            let startup_cfg = store::read_config();
            startup::spawn_background_boot(app.handle().clone(), gw, pm, startup_cfg.clone());

            trayicon::install_tray(app, &startup_cfg)?;

            popover::setup_popover(app);

            popover::setup_window_hooks(app);

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            config_get, config_save, provider_upsert, provider_delete, provider_set_active, provider_test,
            plugin_list, plugin_status, plugin_set_enabled,
            plugin_action, plugin_action_load,
            plugin_install, plugin_uninstall, plugin_open_dir,
            plugin_install_git, plugin_check_update, plugin_update,
            claude_connect, claude_disconnect, set_connect_target, desktop_replay, chatgpt_replay,
            server_status, gateway_set_enabled, usage_get, monitor_get, monitor_clear, logs_get, logs_clear,
            app_open_main, app_quit, window_settings_mode, window_view_min_width,
            history_projects, history_list, history_get, history_search, history_dirs, history_pick_dir, history_set_active,
            history_import, history_import_paths, history_remove_import, history_set_meta, history_delete_forever, history_export_raw, history_export_html,
            util_copy, util_open_external,
            update_state, update_check, update_download, update_apply, update_set_auto,
            skills_list, skills_status, skills_detail, skills_read_file, skills_tools,
            skills_pick_local, skills_scan_local, skills_import_local, skills_import_git,
            skills_refresh, skills_update, skills_delete, skills_sync, skills_unsync,
            skills_set_tags, skills_open_root,
            selfcheck_report, selfcheck_routing, selfcheck_gateway, selfcheck_history, selfcheck_export, selfcheck_import, selfcheck_popover
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            // Keep running in the tray when the user closes the window (hide instead of quit).
            if let tauri::RunEvent::WindowEvent {
                label,
                event: tauri::WindowEvent::CloseRequested { api, .. },
                ..
            } = event
            {
                if let Some(w) = app_handle.get_webview_window(&label) {
                    let _ = w.hide();
                }
                // Closing the main window drops the Dock icon back to menu-bar-only.
                if label == "main" {
                    set_dock_visible(app_handle, false);
                }
                api.prevent_close();
            }
        });
}
