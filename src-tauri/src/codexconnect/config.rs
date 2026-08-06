// Where Codex's config.toml lives (CODEX_HOME / CCBUD_CODEX_CONFIG aware) and how we read and
// write it. toml_edit keeps the user's other settings, comments and formatting untouched; writes
// go through a tmp+rename so a crash mid-write never leaves a torn config.

use std::fs;
use std::path::PathBuf;
use toml_edit::DocumentMut;

pub(super) const PROVIDER_ID: &str = "ccbud";

pub(super) fn home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}

pub fn config_path() -> PathBuf {
    if let Ok(p) = std::env::var("CCBUD_CODEX_CONFIG") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    match std::env::var("CODEX_HOME") {
        Ok(h) if !h.trim().is_empty() => PathBuf::from(h).join("config.toml"),
        _ => home().join(".codex").join("config.toml"),
    }
}

/// Whether Codex is installed enough to connect (its config dir or config file exists). We don't
/// require the file to pre-exist — connect creates it — but we do want ~/.codex to be present so we
/// don't spuriously offer Codex to users who don't have it.
pub fn is_available() -> bool {
    let p = config_path();
    p.exists() || p.parent().map(|d| d.is_dir()).unwrap_or(false)
}

pub(super) fn read_doc() -> DocumentMut {
    fs::read_to_string(config_path())
        .ok()
        .and_then(|s| s.parse::<DocumentMut>().ok())
        .unwrap_or_default()
}

pub(super) fn write_doc(doc: &DocumentMut) -> std::io::Result<()> {
    let p = config_path();
    if let Some(dir) = p.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let tmp = p.with_extension("ccbud.tmp");
    fs::write(&tmp, doc.to_string())?;
    fs::rename(&tmp, &p)
}

pub(super) fn gateway_base(port: u16) -> String {
    format!("http://localhost:{}/v1", port)
}
