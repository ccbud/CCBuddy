// App boot sequencing.
//
// Cold-start rule: the Tauri main thread must only build the window, tray and event hooks.
// Every filesystem-heavy step that used to run synchronously inside `setup()` — one-time
// dir migrations, plugin reconcile, CLI connection repair, gateway/plugin start, history
// watcher registration and the usage-cache warm — runs here, off the main thread, in the
// same relative order as before. This is what keeps the window from showing a white,
// busy-cursor shell while the disk is being scanned.

use serde_json::{json, Value};
use tauri::{Emitter, Manager};

/// Fire-and-forget boot chain. Ordering preserved from the old synchronous setup():
/// 1. one-time historyDirs migrations (must precede the watcher so new trees get watched)
/// 2. plugin reconcile + persisted CLI connection repair + login-item refresh
/// 3. gateway + active plugin start
/// 4. history watcher registration + usage cache warm
/// 5. tray refresh + change events so an already-loaded renderer reconciles
pub fn spawn_background_boot(
    app: tauri::AppHandle,
    gw: std::sync::Arc<crate::gateway::GatewayState>,
    pm: std::sync::Arc<crate::plugin::PluginManager>,
    startup_cfg: Value,
) {
    tauri::async_runtime::spawn(async move {
        let pm_fs = pm.clone();
        let app_fs = app.clone();
        let open_at_login = startup_cfg
            .get("openAtLogin")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let fs_phase = tauri::async_runtime::spawn_blocking(move || {
            // One-time migrations: detected installs of the other coding CLIs (Codex, Grok
            // Build, Copilot CLI, Antigravity CLI, Qoder) and an XDG Claude tree join
            // historyDirs as regular work dirs. `|` (not `||`) — every probe must run.
            let migrated = crate::store::ensure_codex_dir()
                | crate::store::ensure_xdg_claude_dir()
                | crate::store::ensure_grok_dir()
                | crate::store::ensure_copilot_dir()
                | crate::store::ensure_antigravity_dir()
                | crate::store::ensure_qoder_dir();
            // Reconcile services with installed plugins, then repair previously managed
            // CLI targets that remain selected. Startup never connects a first-time target
            // or disconnects one.
            pm_fs.sync_providers();
            let cfg = crate::store::read_config();
            crate::reconcile_connections_on_startup(&cfg);
            // Rewrite the login item to the current exe path — in-place hot updates (and
            // the one-time bundle rename) otherwise leave it pointing at a binary that no
            // longer exists.
            if open_at_login {
                use tauri_plugin_autostart::ManagerExt;
                let _ = app_fs.autolaunch().enable();
            }
            (migrated, cfg)
        })
        .await;
        let (migrated, cfg) = match fs_phase {
            Ok(v) => v,
            Err(_) => (false, startup_cfg.clone()),
        };

        // Gateway + the active plugin-backed service (if any) — the active service would
        // otherwise be dead until the user re-enables its plugin.
        let port = cfg.get("port").and_then(|v| v.as_u64()).unwrap_or(8788) as u16;
        let enabled = cfg.get("gatewayEnabled").and_then(|v| v.as_bool()).unwrap_or(true);
        if enabled {
            if let Err(e) = gw.start(port).await {
                eprintln!("[ccbud] gateway start failed: {}", e);
            }
        }
        if let Some(pid) = active_plugin_id(&cfg) {
            if let Err(e) = pm.start(&pid).await {
                eprintln!("[ccbud] active plugin '{}' start failed: {}", pid, e);
            }
        }

        // Watcher + usage warm live on a detached thread for the app's lifetime.
        let app_watch = app.clone();
        std::thread::spawn(move || start_history_watch_and_warm(&app_watch));

        // Reflect the real gateway/connection state in the tray, and let an already-loaded
        // renderer reconcile with any config the migrations/plugin sync just changed.
        crate::refresh_tray_menu(&app);
        let _ = app.emit("config:changed", crate::store::read_config());
        if migrated {
            let _ = app.emit("history:changed", json!({ "files": [] }));
        }
    });
}

/// Plugin id backing the active provider, if the active provider is plugin-backed.
fn active_plugin_id(cfg: &Value) -> Option<String> {
    cfg.get("activeProviderId")
        .and_then(|v| v.as_str())
        .and_then(|aid| {
            cfg.get("providers")
                .and_then(|v| v.as_array())
                .and_then(|arr| {
                    arr.iter()
                        .find(|p| p.get("id").and_then(|v| v.as_str()) == Some(aid))
                })
        })
        .filter(|p| p.get("backend").and_then(|v| v.as_str()) == Some("plugin"))
        .and_then(|p| p.get("pluginId").and_then(|v| v.as_str()))
        .map(|s| s.to_string())
}

/// History live-watch (fs events on the projects dirs → history:changed) + the startup
/// usage-cache warm, so the FIRST popover open is instant instead of paying the cold-scan
/// cost. Recursive watch registration walks every projects tree — precisely the work that
/// must never run on the UI thread.
fn start_history_watch_and_warm(app: &tauri::AppHandle) {
    use notify_debouncer_mini::{new_debouncer, notify::RecursiveMode, DebounceEventResult};
    let app_w = app.clone();
    if let Ok(mut deb) = new_debouncer(
        std::time::Duration::from_millis(250),
        move |res: DebounceEventResult| {
            if let Ok(events) = res {
                let files: Vec<String> = events
                    .iter()
                    .map(|e| e.path.to_string_lossy().to_string())
                    .collect();
                let _ = app_w.emit("history:changed", json!({ "files": files }));
                // History changed → drop the stale usage cache and re-warm off-thread
                // (+ refresh the tray title) so the next popover open stays instant.
                crate::usage::invalidate_cache();
                let h = app_w.clone();
                std::thread::spawn(move || warm_usage_cache(&h));
            }
        },
    ) {
        for root in crate::history::watch_roots(&crate::store::read_config()) {
            if root.is_dir() {
                let _ = deb.watcher().watch(&root, RecursiveMode::Recursive);
            }
        }
        std::mem::forget(deb); // keep watching for the app's lifetime
    }
    warm_usage_cache(app);
}

/// Warm the usage cache and surface the scan shape in the settings Logs panel — the first
/// place to look when the usage numbers look wrong — then sync the tray usage title.
fn warm_usage_cache(app: &tauri::AppHandle) {
    let cfg = crate::store::read_config();
    crate::usage::warm_cache(&cfg, "all");
    if let Some(g) = app.try_state::<std::sync::Arc<crate::gateway::GatewayState>>() {
        g.log("info", crate::usage::diag(&cfg, "all"));
    }
    crate::update_tray_title(app);
}

/// Older installs live in "ccbud.app" (pre-1.3.4) or "CCBuddy.app" (1.3.4). The
/// in-app updater swaps the bundle's contents but never the folder itself, and
/// macOS shows CFBundleDisplayName only when the folder name matches CFBundleName
/// ("CC Buddy") — any mismatch makes the Dock and the Applications list fall back
/// to the folder name. Rename the bundle once, relaunch from the new path so
/// Launch Services re-registers it, and exit. Bails out on any obstacle
/// (translocation, read-only volume, name already taken) and keeps running under
/// the old name.
#[cfg(target_os = "macos")]
pub fn migrate_legacy_bundle_name() {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(_) => return,
    };
    // exe = <dir>/<legacy>.app/Contents/MacOS/<bin>
    let bundle = match exe.ancestors().nth(3) {
        Some(p)
            if matches!(
                p.file_name().and_then(|n| n.to_str()),
                Some("ccbud.app") | Some("CCBuddy.app")
            ) =>
        {
            p.to_path_buf()
        }
        _ => return,
    };
    let target = match bundle.parent() {
        Some(dir) => dir.join("CC Buddy.app"),
        None => return,
    };
    if target.exists() || std::fs::rename(&bundle, &target).is_err() {
        return;
    }
    // `open -n` asks Launch Services to start a fresh instance from the new path
    // (which also re-registers the name). Wait for its verdict rather than exiting
    // on spawn: a refusal must restore the old name so the running process keeps a
    // valid bundle path behind it instead of leaving the user with nothing open.
    let launched = std::process::Command::new("/usr/bin/open")
        .arg("-n")
        .arg(&target)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if launched {
        std::process::exit(0);
    }
    let _ = std::fs::rename(&target, &bundle);
}
