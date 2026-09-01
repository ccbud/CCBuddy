use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn root() -> Result<PathBuf, String> {
    if let Some(value) = nonempty_env("CCBUD_HOME") {
        return absolute(value, "CCBUD_HOME").map(|path| path.join("skills"));
    }
    Ok(home_dir()?.join(".ccbud/skills"))
}

pub fn ensure_root_at(root: &Path) -> Result<PathBuf, String> {
    std::fs::create_dir_all(root)
        .map_err(|e| format!("create skills root {}: {e}", root.display()))?;
    root.canonicalize()
        .map_err(|e| format!("resolve skills root {}: {e}", root.display()))
}

pub fn validate_id(id: &str) -> Result<(), String> {
    if id.is_empty() || id.starts_with('.') || id.len() > 120 {
        return Err("invalid skill id".into());
    }
    let mut parts = Path::new(id).components();
    if !matches!(parts.next(), Some(Component::Normal(_))) || parts.next().is_some() {
        return Err("invalid skill id".into());
    }
    if !id
        .chars()
        .all(|c| c.is_alphanumeric() || matches!(c, '-' | '_' | '.'))
    {
        return Err("invalid skill id".into());
    }
    Ok(())
}

pub fn skill_dir_at(root: &Path, id: &str) -> Result<PathBuf, String> {
    validate_id(id)?;
    Ok(root.join(id))
}

pub fn existing_skill_dir(root: &Path, id: &str) -> Result<PathBuf, String> {
    let root = ensure_root_at(root)?;
    existing_skill_dir_at(&root, id)
}

pub fn existing_skill_dir_readonly(root: &Path, id: &str) -> Result<PathBuf, String> {
    let root = root
        .canonicalize()
        .map_err(|_| format!("skill not found: {id}"))?;
    if !root.is_dir() {
        return Err(format!("skill not found: {id}"));
    }
    existing_skill_dir_at(&root, id)
}

fn existing_skill_dir_at(root: &Path, id: &str) -> Result<PathBuf, String> {
    let path = skill_dir_at(&root, id)?;
    let meta = std::fs::symlink_metadata(&path).map_err(|_| format!("skill not found: {id}"))?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err(format!("unsafe skill directory: {id}"));
    }
    let canonical = path
        .canonicalize()
        .map_err(|e| format!("resolve skill {id}: {e}"))?;
    if canonical.parent() != Some(root) || !regular_file(&canonical.join("SKILL.md")) {
        return Err(format!("invalid skill directory: {id}"));
    }
    Ok(canonical)
}

pub fn safe_file(root: &Path, relative: &str) -> Result<PathBuf, String> {
    if relative.is_empty() || relative.len() > 1024 {
        return Err("invalid file path".into());
    }
    if Path::new(relative)
        .components()
        .any(|c| !matches!(c, Component::Normal(_)))
    {
        return Err("file path must be relative".into());
    }
    let base = root
        .canonicalize()
        .map_err(|e| format!("resolve skill directory: {e}"))?;
    let path = base.join(relative);
    let resolved = path
        .canonicalize()
        .map_err(|e| format!("resolve skill file: {e}"))?;
    if !resolved.starts_with(&base) || !resolved.is_file() {
        return Err("file is outside the skill directory".into());
    }
    Ok(resolved)
}

pub fn remove_direct_child(root: &Path, path: &Path) -> Result<(), String> {
    if path.parent() != Some(root) {
        return Err(format!("refusing to delete outside {}", root.display()));
    }
    let meta = match std::fs::symlink_metadata(path) {
        Ok(value) => value,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("inspect {}: {e}", path.display())),
    };
    if meta.file_type().is_symlink() {
        return remove_link(path);
    }
    if meta.is_dir() {
        std::fs::remove_dir_all(path).map_err(|e| format!("remove {}: {e}", path.display()))
    } else {
        std::fs::remove_file(path).map_err(|e| format!("remove {}: {e}", path.display()))
    }
}

#[cfg(unix)]
fn remove_link(path: &Path) -> Result<(), String> {
    std::fs::remove_file(path).map_err(|e| format!("remove link {}: {e}", path.display()))
}

#[cfg(windows)]
fn remove_link(path: &Path) -> Result<(), String> {
    std::fs::remove_dir(path)
        .or_else(|_| std::fs::remove_file(path))
        .map_err(|e| format!("remove link {}: {e}", path.display()))
}

pub fn home_dir() -> Result<PathBuf, String> {
    resolve_home(
        nonempty_env("HOME"),
        nonempty_env("USERPROFILE"),
        nonempty_env("HOMEDRIVE"),
        nonempty_env("HOMEPATH"),
        cfg!(windows),
    )
}

pub(crate) fn resolve_home(
    home: Option<OsString>,
    user_profile: Option<OsString>,
    home_drive: Option<OsString>,
    home_path: Option<OsString>,
    windows: bool,
) -> Result<PathBuf, String> {
    if let Some(value) = home {
        return absolute(value, "HOME");
    }
    if windows {
        if let Some(value) = user_profile {
            return absolute(value, "USERPROFILE");
        }
        if let (Some(drive), Some(path)) = (home_drive, home_path) {
            let mut combined = drive;
            combined.push(path);
            return absolute(combined, "HOMEDRIVE/HOMEPATH");
        }
    }
    Err("cannot resolve an absolute user home directory".into())
}

pub(crate) fn regular_file(path: &Path) -> bool {
    std::fs::symlink_metadata(path)
        .map(|meta| meta.is_file() && !meta.file_type().is_symlink())
        .unwrap_or(false)
}

fn nonempty_env(name: &str) -> Option<OsString> {
    std::env::var_os(name).filter(|value| !value.is_empty())
}

fn absolute(value: OsString, name: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(value);
    if path.is_absolute() {
        Ok(path)
    } else {
        Err(format!("{name} must be an absolute path"))
    }
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}
