// The Tauri IPC surface, split by topic.
//
// Every #[tauri::command] the renderer invokes lives in one of the modules below, moved verbatim
// out of lib.rs. Each command is `pub(crate)` and re-exported here so lib.rs can keep listing
// them unqualified in `tauri::generate_handler![…]` via `use commands::*;`. Shared statics
// (LAST_START_ERROR, UPDATE_*, AUTO_UPDATE_*) live with their topic module.

mod autoupdate;
mod config;
mod connect;
mod gateway;
mod history;
mod history_export;
mod plugins;
mod provider_test;
mod replay;
mod selfcheck;
mod selfcheck_js;
mod skills;
mod update;
mod util;
mod window;
#[cfg(test)]
mod fmt_tests;

pub(crate) use autoupdate::auto_update_on_visible;
pub(crate) use config::{
    config_get, config_save, provider_delete, provider_set_active, provider_upsert,
};
pub(crate) use connect::{
    claude_connect, claude_disconnect, gateway_set_enabled, reconcile_connections_on_startup,
    set_connect_target,
};
// Exercised by the #[cfg(test)] module via these re-exports, so a non-test `cargo check` sees
// them as unused — allow that, don't drop the API.
#[allow(unused_imports)]
pub(crate) use connect::{ensure_hero_connect_target, startup_reconcile_targets};
pub(crate) use gateway::{
    format_tokens, full_status, logs_clear, logs_get, monitor_clear, monitor_get, server_status,
    usage_get,
};
pub(crate) use history::{
    history_delete_forever, history_dirs, history_get, history_import, history_import_paths,
    history_list, history_pick_dir, history_projects, history_remove_import, history_search,
    history_set_active, history_set_meta,
};
pub(crate) use history_export::{history_export_html, history_export_raw};
pub(crate) use plugins::{
    plugin_action, plugin_action_load, plugin_check_update, plugin_install, plugin_install_git,
    plugin_list, plugin_open_dir, plugin_set_enabled, plugin_status, plugin_uninstall,
    plugin_update,
};
pub(crate) use provider_test::provider_test;
pub(crate) use replay::{chatgpt_replay, desktop_replay};
pub(crate) use selfcheck::{
    selfcheck_export, selfcheck_gateway, selfcheck_history, selfcheck_import, selfcheck_popover,
    selfcheck_report, selfcheck_routing,
};
pub(crate) use selfcheck_js::{POPOVER_SELFCHECK_JS, SELFCHECK_JS};
pub(crate) use skills::{
    skills_delete, skills_detail, skills_import_git, skills_import_local, skills_list,
    skills_open_root, skills_pick_local, skills_read_file, skills_refresh, skills_scan_local,
    skills_set_tags, skills_status, skills_sync, skills_tools, skills_unsync, skills_update,
};
pub(crate) use update::{
    update_apply, update_check, update_download, update_set_auto, update_state,
};
pub(crate) use util::{util_copy, util_open_external};
pub(crate) use window::{
    app_open_main, app_quit, set_dock_visible, window_settings_mode, window_view_min_width,
};
