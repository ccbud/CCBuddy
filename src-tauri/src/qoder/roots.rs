// Qoder data roots and the container-shape path test used for routing. Moved verbatim from
// qoder.rs.

use std::path::{Path, PathBuf};

pub(super) fn home() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
}

/// Qoder's two known data roots (both observed in the wild): each is a history-dir entry
/// candidate for the auto-add migration; browsing itself walks every configured dir's
/// `projects/` tree, so these only seed historyDirs.
pub fn default_root() -> PathBuf {
    home().join(".qoder")
}

pub fn work_root() -> PathBuf {
    home().join(".qoderwork")
}

/// A qoder install exists at `root` when its projects tree is on disk.
pub fn root_exists(root: &Path) -> bool {
    root.join("projects").is_dir()
}

/// Container-shape test for routing: a .jsonl anywhere under a `.qoder/projects/` or
/// `.qoderwork/projects/` tree (main sessions AND `<uuid>/subagents/agent-*.jsonl`).
pub fn looks_qoder_path(file: &Path) -> bool {
    if file.extension().and_then(|e| e.to_str()) != Some("jsonl") {
        return false;
    }
    let mut child: Option<&std::ffi::OsStr> = None;
    for anc in file.ancestors().skip(1) {
        let name = match anc.file_name() {
            Some(n) => n,
            None => break,
        };
        if (name == ".qoder" || name == ".qoderwork")
            && child.map(|c| c == "projects").unwrap_or(false)
        {
            return true;
        }
        child = Some(name);
    }
    false
}
