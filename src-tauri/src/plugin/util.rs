// Free helpers shared by the manager: ids, platform keys, ports, paths, base64, GitHub raw
// URLs, version comparison, the child-process PATH, and a recursive copy. Moved verbatim from
// plugin.rs.

use std::path::PathBuf;
use std::process::{Command, Stdio};

pub(super) fn provider_id(plugin_id: &str) -> String {
    format!("plugin:{}", plugin_id)
}

/// `<os>-<arch>` matching plugin.json's runtime.exec keys.
pub(super) fn platform_key() -> &'static str {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => "darwin-arm64",
        ("macos", "x86_64") => "darwin-amd64",
        ("linux", "x86_64") => "linux-amd64",
        ("linux", "aarch64") => "linux-arm64",
        ("windows", "x86_64") => "windows-amd64",
        _ => "unknown",
    }
}

pub(super) fn free_port() -> Option<u16> {
    std::net::TcpListener::bind("127.0.0.1:0")
        .ok()
        .and_then(|l| l.local_addr().ok())
        .map(|a| a.port())
}

/// True if we can bind 127.0.0.1:port right now (i.e. nothing else is holding it).
pub(super) fn port_is_free(port: u16) -> bool {
    port != 0 && std::net::TcpListener::bind(("127.0.0.1", port)).is_ok()
}

/// ccbud config home (~/.ccbud, overridable via CCBUD_HOME) — mirrors store.rs.
pub(super) fn ccbud_home() -> PathBuf {
    if let Ok(v) = std::env::var("CCBUD_HOME") {
        if !v.trim().is_empty() {
            return PathBuf::from(v);
        }
    }
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".ccbud")
}

/// ~/.ccbud/plugins — where plugins are installed.
pub fn plugins_root() -> PathBuf {
    ccbud_home().join("plugins")
}

/// Minimal standard base64 — used only to embed a small plugin icon as a data URI.
pub(super) fn base64_encode(input: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((input.len() + 2) / 3 * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0];
        let b1 = *chunk.get(1).unwrap_or(&0);
        let b2 = *chunk.get(2).unwrap_or(&0);
        out.push(T[(b0 >> 2) as usize] as char);
        out.push(T[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
        out.push(if chunk.len() > 1 { T[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[(b2 & 0x3f) as usize] as char } else { '=' });
    }
    out
}

/// Convert a github.com repo URL + branch into a raw file URL.
pub(super) fn github_raw(git: &str, branch: &str, path: &str) -> Option<String> {
    let g = git.trim().trim_end_matches('/').trim_end_matches(".git");
    let rest = g
        .strip_prefix("https://github.com/")
        .or_else(|| g.strip_prefix("http://github.com/"))
        .or_else(|| g.strip_prefix("git@github.com:"))?;
    let br = if branch.trim().is_empty() { "main" } else { branch.trim() };
    Some(format!("https://raw.githubusercontent.com/{}/{}/{}", rest, br, path))
}

/// True if a git URL points at the official `ccbud` org on github.
pub(super) fn is_official_source(git: &str) -> bool {
    let g = git.trim().trim_end_matches('/').trim_end_matches(".git");
    g.strip_prefix("https://github.com/")
        .or_else(|| g.strip_prefix("http://github.com/"))
        .or_else(|| g.strip_prefix("git@github.com:"))
        .and_then(|rest| rest.split('/').next())
        .map(|owner| owner.eq_ignore_ascii_case("ccbud"))
        .unwrap_or(false)
}

/// True if semver-ish `a` is strictly newer than `b` (e.g. "0.2.0" > "0.1.9").
pub(super) fn version_gt(a: &str, b: &str) -> bool {
    parse_ver(a) > parse_ver(b)
}
pub(super) fn parse_ver(v: &str) -> Vec<u64> {
    v.trim()
        .trim_start_matches('v')
        .split(|c| c == '.' || c == '-' || c == '+')
        .map(|s| s.parse::<u64>().unwrap_or(0))
        .collect()
}
/// PATH for `source.build` commands. A GUI app launched from Finder/the Dock
/// inherits launchd's minimal PATH (no Homebrew, no /usr/local/go/bin, …), so
/// builds die with e.g. "go: command not found" even though the toolchain works
/// fine in the user's terminal. Merge the inherited PATH with the login shell's
/// PATH plus well-known toolchain dirs.
pub(super) fn build_env_path() -> std::ffi::OsString {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    if let Some(p) = login_shell_path() {
        for d in std::env::split_paths(&p) {
            if !dirs.contains(&d) {
                dirs.push(d);
            }
        }
    }
    // Cover toolchains even when the login shell probe fails (or exports them
    // only for interactive shells): Homebrew, the official Go installer, and
    // per-user go/cargo/pip bin dirs.
    let mut extras: Vec<PathBuf> =
        ["/usr/local/bin", "/opt/homebrew/bin", "/usr/local/go/bin"].iter().map(PathBuf::from).collect();
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        extras.extend(["go/bin", ".cargo/bin", ".local/bin"].iter().map(|d| home.join(d)));
    }
    for d in extras {
        if d.is_dir() && !dirs.contains(&d) {
            dirs.push(d);
        }
    }
    std::env::join_paths(dirs).unwrap_or_else(|_| std::env::var_os("PATH").unwrap_or_default())
}

/// Ask the user's login shell for its PATH (profiles are where Homebrew, Go,
/// cargo, … register themselves). Best-effort: any failure returns None.
pub(super) fn login_shell_path() -> Option<String> {
    let shell = std::env::var("SHELL").ok().filter(|s| !s.trim().is_empty())?;
    let out = Command::new(shell)
        .args(["-l", "-c", "env"])
        .stdin(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    // Profile scripts may print noise before `env` runs; take the last PATH= line.
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .rev()
        .find_map(|l| l.strip_prefix("PATH=").map(|v| v.to_string()))
        .filter(|p| !p.trim().is_empty())
}

/// A process-unique-ish suffix for temporary import directories.
pub(super) fn unique_suffix() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{}-{}", std::process::id(), nanos)
}

/// Recursively copy a directory tree (files + subdirs; symlinks skipped).
pub(super) fn copy_dir_all(src: &std::path::Path, dst: &std::path::Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        if entry.file_name() == ".git" {
            continue; // never copy VCS metadata into an install dir
        }
        let ty = entry.file_type()?;
        let from = entry.path();
        let to = dst.join(entry.file_name());
        if ty.is_dir() {
            copy_dir_all(&from, &to)?;
        } else if ty.is_file() {
            std::fs::copy(&from, &to)?;
        }
    }
    Ok(())
}
