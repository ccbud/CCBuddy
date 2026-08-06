// Where the config lives, the write lock, home-collapsing, the small JSON accessors, the 0600
// permission helper and provider id generation. Moved verbatim from store.rs.

use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, OnceLock};

pub fn ccbud_home() -> PathBuf {
    if let Ok(d) = std::env::var("CCBUD_HOME") {
        if !d.is_empty() {
            return PathBuf::from(d);
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".ccbud")
}

pub(super) fn config_file() -> PathBuf {
    ccbud_home().join("config.json")
}

pub(super) fn config_lock() -> MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Collapse a home-prefixed absolute path back to `~` form so the UI shows
/// `~/.claude` instead of `/Users/<name>/.claude`. Inverse of history::expand_tilde.
pub fn collapse_home(p: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    if home.is_empty() {
        return p.to_string();
    }
    let home = home.trim_end_matches('/');
    if p == home {
        return "~".to_string();
    }
    if let Some(rest) = p.strip_prefix(&format!("{}/", home)) {
        return format!("~/{}", rest);
    }
    p.to_string()
}

pub(super) fn str_of(v: Option<&Value>) -> String {
    v.and_then(|x| x.as_str()).unwrap_or("").to_string()
}
pub(super) fn bool_of(v: Option<&Value>, default: bool) -> bool {
    v.and_then(|x| x.as_bool()).unwrap_or(default)
}

#[cfg(unix)]
pub(super) fn set_0600(p: &PathBuf) {
    use std::os::unix::fs::PermissionsExt;
    let _ = fs::set_permissions(p, fs::Permissions::from_mode(0o600));
}
#[cfg(not(unix))]
pub(super) fn set_0600(_p: &PathBuf) {}

/// Stable-enough unique id for a new provider (single-user, serialized writes).
pub fn gen_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("p{}", n)
}
