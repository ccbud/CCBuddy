// Legacy macOS bundle rename, moved verbatim from lib.rs. (run() calls the copy that lives in
// startup.rs; this one is kept as-is by the split.)

/// Older installs live in "ccbud.app" (pre-1.3.4) or "CCBuddy.app" (1.3.4). The
/// in-app updater swaps the bundle's contents but never the folder itself, and
/// macOS shows CFBundleDisplayName only when the folder name matches CFBundleName
/// ("CC Buddy") — any mismatch makes the Dock and the Applications list fall back
/// to the folder name. Rename the bundle once, relaunch from the new path so
/// Launch Services re-registers it, and exit. Bails out on any obstacle
/// (translocation, read-only volume, name already taken) and keeps running under
/// the old name.
#[cfg(target_os = "macos")]
fn migrate_legacy_bundle_name() {
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
