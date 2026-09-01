use sha1::{Digest, Sha1};
use std::ffi::OsStr;
use std::io::Read;
use std::path::Path;

const MAX_DEPTH: usize = 64;
const MAX_ENTRIES: usize = 30_000;
const MAX_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Default)]
struct Budget {
    entries: usize,
    bytes: u64,
}

pub fn confirmation_token(
    skill_id: &str,
    target: &Path,
    keys: &[String],
) -> Result<String, String> {
    confirmation_token_at(skill_id, target, target, keys)
}

pub fn matches_confirmation(
    conflict: &super::model::SyncConflictDto,
    logical_target: &Path,
    state_path: &Path,
) -> Result<bool, String> {
    let token = confirmation_token_at(
        &conflict.skill_id,
        logical_target,
        state_path,
        &conflict.keys,
    )?;
    Ok(token == conflict.fingerprint_token)
}

pub fn retoken_confirmation(
    conflict: &super::model::SyncConflictDto,
    logical_target: &Path,
    state_path: &Path,
) -> Result<super::model::SyncConflictDto, String> {
    let mut refreshed = conflict.clone();
    refreshed.fingerprint_token = confirmation_token_at(
        &conflict.skill_id,
        logical_target,
        state_path,
        &conflict.keys,
    )?;
    Ok(refreshed)
}

pub fn capture_state(
    logical_target: &Path,
    state_path: &Path,
) -> Result<super::model::SyncConflictDto, String> {
    retoken_confirmation(
        &super::model::SyncConflictDto {
            skill_id: String::new(),
            path: logical_target.to_string_lossy().to_string(),
            keys: Vec::new(),
            fingerprint_token: String::new(),
        },
        logical_target,
        state_path,
    )
}

fn confirmation_token_at(
    skill_id: &str,
    logical_target: &Path,
    state_path: &Path,
    keys: &[String],
) -> Result<String, String> {
    let mut digest = Sha1::new();
    update_bytes(&mut digest, b"ccbud-skills-overwrite-v1");
    update_bytes(&mut digest, skill_id.as_bytes());
    update_os(&mut digest, logical_target.as_os_str());
    for key in keys {
        update_bytes(&mut digest, key.as_bytes());
    }
    fingerprint_node(
        state_path,
        state_path,
        0,
        &mut Budget::default(),
        &mut digest,
    )?;
    Ok(format!("v1:{:x}", digest.finalize()))
}

fn fingerprint_node(
    root: &Path,
    path: &Path,
    depth: usize,
    budget: &mut Budget,
    digest: &mut Sha1,
) -> Result<(), String> {
    if depth > MAX_DEPTH {
        return Err(format!(
            "overwrite target exceeds maximum depth: {}",
            path.display()
        ));
    }
    if depth > 0 {
        budget.entries += 1;
        if budget.entries > MAX_ENTRIES {
            return Err("overwrite target contains too many entries".into());
        }
    }
    let before = std::fs::symlink_metadata(path)
        .map_err(|error| format!("inspect overwrite target {}: {error}", path.display()))?;
    let before_stable = super::target_identity::stable(&before);
    let before_version = super::target_identity::version(&before);
    let relative = path.strip_prefix(root).unwrap_or(path);
    update_os(digest, relative.as_os_str());
    update_bytes(digest, &before_stable);

    let file_type = before.file_type();
    if file_type.is_symlink() {
        let destination = std::fs::read_link(path)
            .map_err(|error| format!("read overwrite target link {}: {error}", path.display()))?;
        update_bytes(digest, b"symlink");
        update_os(digest, destination.as_os_str());
    } else if before.is_file() {
        update_bytes(digest, b"file");
        let mut file = std::fs::File::open(path)
            .map_err(|error| format!("read overwrite target {}: {error}", path.display()))?;
        let mut buffer = vec![0_u8; 64 * 1024];
        loop {
            let read = file
                .read(&mut buffer)
                .map_err(|error| format!("read overwrite target {}: {error}", path.display()))?;
            if read == 0 {
                break;
            }
            add_bytes(budget, read as u64)?;
            digest.update(&buffer[..read]);
        }
    } else if before.is_dir() {
        update_bytes(digest, b"directory");
        let reader = std::fs::read_dir(path)
            .map_err(|error| format!("read overwrite target {}: {error}", path.display()))?;
        let remaining = MAX_ENTRIES.saturating_sub(budget.entries);
        let mut entries = Vec::with_capacity(remaining.min(1024));
        for entry in reader.take(remaining + 1) {
            entries.push(
                entry.map_err(|error| {
                    format!("read overwrite target {}: {error}", path.display())
                })?,
            );
            if entries.len() > remaining {
                return Err("overwrite target contains too many entries".into());
            }
        }
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            fingerprint_node(root, &entry.path(), depth + 1, budget, digest)?;
        }
    } else {
        return Err(format!(
            "unsupported overwrite target filesystem type: {}",
            path.display()
        ));
    }

    let after = std::fs::symlink_metadata(path)
        .map_err(|error| format!("overwrite target changed: {}: {error}", path.display()))?;
    if super::target_identity::stable(&after) != before_stable
        || super::target_identity::version(&after) != before_version
    {
        return Err(format!(
            "overwrite target changed while inspecting: {}",
            path.display()
        ));
    }
    Ok(())
}

fn add_bytes(budget: &mut Budget, count: u64) -> Result<(), String> {
    budget.bytes = budget
        .bytes
        .checked_add(count)
        .ok_or_else(|| "overwrite target content is too large".to_string())?;
    if budget.bytes > MAX_BYTES {
        return Err("overwrite target content is too large".into());
    }
    Ok(())
}

fn update_bytes(digest: &mut Sha1, value: &[u8]) {
    digest.update((value.len() as u64).to_le_bytes());
    digest.update(value);
}

#[cfg(unix)]
fn update_os(digest: &mut Sha1, value: &OsStr) {
    use std::os::unix::ffi::OsStrExt;
    update_bytes(digest, value.as_bytes());
}

#[cfg(windows)]
fn update_os(digest: &mut Sha1, value: &OsStr) {
    use std::os::windows::ffi::OsStrExt;
    let bytes: Vec<u8> = value.encode_wide().flat_map(u16::to_le_bytes).collect();
    update_bytes(digest, &bytes);
}

#[cfg(not(any(unix, windows)))]
fn update_os(digest: &mut Sha1, value: &OsStr) {
    update_bytes(digest, value.to_string_lossy().as_bytes());
}
