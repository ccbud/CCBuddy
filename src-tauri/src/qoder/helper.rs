// Locating Qoder's installed CLI binary and proving it is trustworthy before executing it.
// macOS-only (declared `#[cfg(target_os = "macos")] mod helper;`), moved verbatim from qoder.rs.

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};

use super::guard::denied;
use super::read::mtime_ms_of;
use super::roots::{default_root, home};

#[cfg(target_os = "macos")]
fn helper_from_install_dir(install_dir: &Path) -> io::Result<PathBuf> {
    let canonical_dir = fs::canonicalize(install_dir)?;
    if !fs::metadata(&canonical_dir)?.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "Qoder CLI helper install directory is not a directory",
        ));
    }

    let version_path = fs::canonicalize(canonical_dir.join("version.txt"))?;
    if version_path.parent() != Some(canonical_dir.as_path()) {
        return Err(denied(
            "Qoder CLI version file escapes its install directory",
        ));
    }
    let version = fs::read_to_string(version_path)?;
    let version = version.trim();
    if version.is_empty()
        || version.len() > 64
        || !version
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Qoder CLI version.txt contains an invalid version",
        ));
    }

    let helper = fs::canonicalize(canonical_dir.join(format!("qodercli-{version}")))?;
    if helper.parent() != Some(canonical_dir.as_path()) || !fs::metadata(&helper)?.is_file() {
        return Err(denied("Qoder CLI helper escapes its install directory"));
    }
    Ok(helper)
}

#[cfg(target_os = "macos")]
pub(super) fn installed_qoder_helper(current_root: &Path) -> io::Result<PathBuf> {
    let current_install = current_root.join("bin").join("qodercli");
    let home_install = default_root().join("bin").join("qodercli");

    let mut last_error = None;
    for install_dir in [&current_install, &home_install] {
        match helper_from_install_dir(install_dir) {
            Ok(helper) => return Ok(helper),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.unwrap_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "installed Qoder CLI helper was not found",
        )
    }))
}

/// The helper lives in a user-writable tree, so before executing it must prove it wasn't planted:
/// owned by the same uid as $HOME, neither it nor its directory group/world-writable, a valid
/// strict codesign signature, and a real TeamIdentifier (rejects ad-hoc-signed payloads). Same-uid
/// malware can defeat any same-uid check by definition — the goal is to stop weaker writers and
/// unsigned binaries, and to guarantee a signing-identity trail for anything that does run.
/// codesign hashes the whole (large) binary, so the verdict is memoized per (path, mtime, size).
#[cfg(target_os = "macos")]
pub(super) fn verify_helper_trust(helper: &Path) -> io::Result<()> {
    static VERDICTS: OnceLock<Mutex<HashMap<PathBuf, (f64, u64, bool)>>> = OnceLock::new();
    let meta = fs::metadata(helper)?;
    let (mt, size) = (mtime_ms_of(&meta), meta.len());
    let cache = VERDICTS.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(guard) = cache.lock() {
        if let Some((cmt, csz, ok)) = guard.get(helper) {
            if *cmt == mt && *csz == size {
                return if *ok {
                    Ok(())
                } else {
                    Err(denied("Qoder CLI helper previously failed trust verification"))
                };
            }
        }
    }
    let verdict = helper_trust_checks(helper, &meta);
    if let Ok(mut guard) = cache.lock() {
        guard.insert(helper.to_path_buf(), (mt, size, verdict.is_ok()));
    }
    verdict
}

#[cfg(target_os = "macos")]
fn helper_trust_checks(helper: &Path, meta: &fs::Metadata) -> io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let home_uid = fs::metadata(home())?.uid();
    let dir_meta = match helper.parent() {
        Some(dir) => fs::metadata(dir)?,
        None => return Err(denied("Qoder CLI helper has no install directory")),
    };
    for (what, m) in [("helper", meta), ("helper directory", &dir_meta)] {
        if m.uid() != home_uid {
            return Err(denied(format!("Qoder CLI {what} is not owned by the current user")));
        }
        if m.mode() & 0o022 != 0 {
            return Err(denied(format!("Qoder CLI {what} is group/world writable")));
        }
    }
    // codesign is Apple's own bounded tool — a plain blocking call is fine here.
    let valid = Command::new("/usr/bin/codesign")
        .args(["--verify", "--strict", "--"])
        .arg(helper)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    if !valid.success() {
        return Err(denied("Qoder CLI helper has no valid code signature"));
    }
    let display = Command::new("/usr/bin/codesign")
        .args(["-d", "--verbose=2", "--"])
        .arg(helper)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()?; // codesign -d prints its details on stderr
    let info = String::from_utf8_lossy(&display.stderr);
    let has_team = info.lines().any(|line| {
        let line = line.trim_start();
        line.starts_with("TeamIdentifier=") && line != "TeamIdentifier=not set"
    });
    if !has_team {
        return Err(denied("Qoder CLI helper is not signed with a developer Team ID"));
    }
    Ok(())
}
