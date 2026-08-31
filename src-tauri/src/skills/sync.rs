use super::model::TargetMeta;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

pub fn sync_targets(
    source: &Path,
    id: &str,
    keys: &[String],
    requested_mode: Option<&str>,
    home: &Path,
    targets: &mut Vec<TargetMeta>,
) -> Result<super::target_tx::SyncTransaction, String> {
    let mode = normalize_mode(requested_mode.unwrap_or("auto"))?;
    let mut keys = dedup(keys);
    keys.sort_by_key(|key| key != "cursor");
    preflight_targets(id, &keys, home, targets)?;
    let mut outcomes: HashMap<PathBuf, String> = HashMap::new();
    let mut transaction = super::target_tx::SyncTransaction::new();
    for key in keys {
        let root = super::tools::target_root(home, &key)?;
        std::fs::create_dir_all(&root)
            .map_err(|e| format!("create tool skills directory {}: {e}", root.display()))?;
        let root = root
            .canonicalize()
            .map_err(|e| format!("resolve tool skills directory: {e}"))?;
        let target = root.join(id);
        let actual = if let Some(existing) = outcomes.get(&target) {
            existing.clone()
        } else {
            let tracked = targets.iter().any(|item| Path::new(&item.path) == target);
            if path_exists(&target)? && !tracked {
                return abort(
                    transaction,
                    format!(
                        "target already exists and is unmanaged: {}",
                        target.display()
                    ),
                );
            }
            let swap =
                match super::target_tx::prepare(source, &root, &target, effective_mode(&key, mode))
                {
                    Ok(value) => value,
                    Err(error) => return abort(transaction, error),
                };
            let actual = swap.actual_mode.clone();
            transaction.push(swap);
            outcomes.insert(target.clone(), actual.clone());
            actual
        };
        targets.retain(|item| item.key != key);
        targets.push(TargetMeta {
            key,
            path: target.to_string_lossy().to_string(),
            sync_mode: actual,
            status: "ok".into(),
        });
    }
    targets.sort_by(|a, b| a.key.cmp(&b.key));
    Ok(transaction)
}

fn preflight_targets(
    id: &str,
    keys: &[String],
    home: &Path,
    targets: &[TargetMeta],
) -> Result<(), String> {
    for key in keys {
        let root = super::tools::target_root(home, key)?;
        let root = if path_exists(&root)? {
            if !root.is_dir() {
                return Err(format!(
                    "tool skills path is not a directory: {}",
                    root.display()
                ));
            }
            root.canonicalize()
                .map_err(|e| format!("resolve tool skills directory: {e}"))?
        } else {
            root
        };
        let target = root.join(id);
        if std::fs::symlink_metadata(&target).is_ok()
            && !targets.iter().any(|item| Path::new(&item.path) == target)
        {
            return Err(format!(
                "target already exists and is unmanaged: {}",
                target.display()
            ));
        }
    }
    Ok(())
}

pub fn unsync_targets(
    id: &str,
    keys: &[String],
    home: &Path,
    targets: &mut Vec<TargetMeta>,
) -> Result<super::target_tx::SyncTransaction, String> {
    let wanted: HashSet<String> = dedup(keys).into_iter().collect();
    for key in &wanted {
        super::tools::find(key).ok_or_else(|| format!("unknown skill tool: {key}"))?;
    }
    let removed: Vec<TargetMeta> = targets
        .iter()
        .filter(|target| wanted.contains(&target.key))
        .cloned()
        .collect();
    let remaining: Vec<&TargetMeta> = targets
        .iter()
        .filter(|target| !wanted.contains(&target.key))
        .collect();
    let mut seen = HashSet::new();
    let mut transaction = super::target_tx::SyncTransaction::new();
    for target in &removed {
        if remaining.iter().any(|other| other.path == target.path)
            || !seen.insert(target.path.clone())
        {
            continue;
        }
        if let Err(error) = stage_recorded_target(id, target, home, &mut transaction) {
            return Err(super::target_tx::rollback_error(transaction, error));
        }
    }
    targets.retain(|target| !wanted.contains(&target.key));
    Ok(transaction)
}

pub fn cleanup_all(
    id: &str,
    home: &Path,
    targets: &[TargetMeta],
) -> Result<super::target_tx::SyncTransaction, String> {
    let mut seen = HashSet::new();
    let mut transaction = super::target_tx::SyncTransaction::new();
    for target in targets {
        if seen.insert(target.path.clone()) {
            if let Err(error) = stage_recorded_target(id, target, home, &mut transaction) {
                return Err(super::target_tx::rollback_error(transaction, error));
            }
        }
    }
    Ok(transaction)
}

fn stage_recorded_target(
    id: &str,
    target: &TargetMeta,
    home: &Path,
    transaction: &mut super::target_tx::SyncTransaction,
) -> Result<(), String> {
    let root = checked_target_root(id, target, home)?;
    if let Some(swap) = super::target_tx::prepare_remove(&root, &root.join(id))? {
        transaction.push(swap);
    }
    Ok(())
}

pub(super) fn checked_target_root(
    id: &str,
    target: &TargetMeta,
    home: &Path,
) -> Result<PathBuf, String> {
    let root = super::tools::target_root(home, &target.key)?;
    let root = if path_exists(&root)? {
        root.canonicalize()
            .map_err(|e| format!("resolve tool target: {e}"))?
    } else {
        root
    };
    if Path::new(&target.path) != root.join(id) {
        return Err(format!("refusing unsafe recorded target: {}", target.path));
    }
    Ok(root)
}

pub(super) fn effective_mode<'a>(key: &str, requested: &'a str) -> &'a str {
    if key == "cursor" {
        "copy"
    } else {
        requested
    }
}

pub(super) fn normalize_mode(mode: &str) -> Result<&str, String> {
    match mode {
        "auto" | "copy" | "symlink" => Ok(mode),
        _ => Err(format!("unsupported sync mode: {mode}")),
    }
}

fn dedup(keys: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    keys.iter()
        .filter(|key| seen.insert((*key).clone()))
        .cloned()
        .collect()
}

fn path_exists(path: &Path) -> Result<bool, String> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!("inspect {}: {error}", path.display())),
    }
}

fn abort(
    transaction: super::target_tx::SyncTransaction,
    error: String,
) -> Result<super::target_tx::SyncTransaction, String> {
    Err(super::target_tx::rollback_error(transaction, error))
}
