// Error shapes and the strict projects-tree validation every privileged helper read must pass.
// Moved verbatim from qoder.rs.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use super::limits::MAX_READ_BYTES;

pub(super) fn denied(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message.into())
}

pub(super) fn too_large() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!(
            "Qoder data file exceeds the {} MiB read limit",
            MAX_READ_BYTES / 1024 / 1024
        ),
    )
}

/// Canonicalize a prospective helper target and prove that it is a JSON/JSONL data file in a
/// `projects` directory directly below a `.qoder` or `.qoderwork` root. Canonicalizing the root,
/// projects directory, and target separately prevents a symlink below `projects` from escaping
/// into an arbitrary part of the filesystem.
pub(super) fn validated_qoder_data_path(path: &Path) -> io::Result<(PathBuf, PathBuf)> {
    let projects = path
        .ancestors()
        .find(|ancestor| {
            ancestor
                .file_name()
                .map(|name| name == "projects")
                .unwrap_or(false)
                && ancestor
                    .parent()
                    .and_then(Path::file_name)
                    .map(|name| name == ".qoder" || name == ".qoderwork")
                    .unwrap_or(false)
        })
        .ok_or_else(|| denied("helper reads are limited to .qoder/.qoderwork projects trees"))?;
    let root = projects
        .parent()
        .ok_or_else(|| denied("Qoder projects directory has no data root"))?;

    let canonical_root = fs::canonicalize(root)?;
    let canonical_projects = fs::canonicalize(projects)?;
    if canonical_projects.parent() != Some(canonical_root.as_path()) {
        return Err(denied("Qoder projects directory escapes its data root"));
    }

    let canonical_path = fs::canonicalize(path)?;
    let relative = canonical_path
        .strip_prefix(&canonical_projects)
        .map_err(|_| denied("Qoder data path escapes its projects directory"))?;
    if relative.as_os_str().is_empty() {
        return Err(denied("Qoder data path must name a file below projects"));
    }

    let is_data_file = matches!(
        canonical_path
            .extension()
            .and_then(|extension| extension.to_str()),
        Some("json") | Some("jsonl")
    );
    if !is_data_file {
        return Err(denied("Qoder helper only reads JSON and JSONL data files"));
    }

    let metadata = fs::metadata(&canonical_path)?;
    if !metadata.is_file() {
        return Err(denied("Qoder data path is not a regular file"));
    }
    if metadata.len() > MAX_READ_BYTES as u64 {
        return Err(too_large());
    }

    Ok((canonical_path, canonical_root))
}
