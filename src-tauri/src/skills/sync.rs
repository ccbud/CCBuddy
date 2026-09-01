use super::model::{SkillsSyncErrorDto, SyncConflictDto, TargetMeta};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

pub fn sync_targets(
    source: &Path,
    id: &str,
    keys: &[String],
    requested_mode: Option<&str>,
    home: &Path,
    targets: &mut Vec<TargetMeta>,
    authorizing: &[SyncConflictDto],
) -> Result<super::target_tx::SyncTransaction, SkillsSyncErrorDto> {
    let mode = normalize_mode(requested_mode.unwrap_or("auto"))?;
    let mut keys = super::sync_plan::dedup(keys);
    keys.sort_by_key(|key| key != "cursor");
    let original_targets = targets.clone();
    let mut execution_ownership = original_targets.clone();
    super::sync_plan::preflight_targets(id, &keys, home, &execution_ownership, authorizing)?;
    let mut outcomes: HashMap<PathBuf, String> = HashMap::new();
    let mut transaction = super::target_tx::SyncTransaction::new();
    for key in keys.iter().cloned() {
        let root = super::tools::target_root(home, &key)?;
        std::fs::create_dir_all(&root)
            .map_err(|e| format!("create tool skills directory {}: {e}", root.display()))?;
        let root = super::sync_plan::resolved_root(home, &key)?;
        let target = root.join(id);
        let actual = if let Some(existing) = outcomes.get(&target) {
            existing.clone()
        } else {
            let expectation = match super::sync_plan::target_expectation(
                id,
                &target,
                &keys,
                home,
                &execution_ownership,
                authorizing,
            ) {
                Ok(value) => value,
                Err(error) => return super::sync_abort::abort(transaction, error),
            };
            let swap = match super::target_prepare::prepare(
                source,
                &root,
                &target,
                effective_mode(&key, mode),
                &expectation,
            ) {
                Ok(value) => value,
                Err(super::target_prepare::PrepareError::Changed) => {
                    return super::sync_abort::abort_confirmation(
                        transaction,
                        id,
                        &keys,
                        home,
                        &original_targets,
                    );
                }
                Err(super::target_prepare::PrepareError::Failed(message)) => {
                    return super::sync_abort::abort(transaction, message.into());
                }
            };
            let actual = swap.actual_mode.clone();
            transaction.push(swap);
            outcomes.insert(target.clone(), actual.clone());
            execution_ownership.push(TargetMeta {
                key: key.clone(),
                path: target.to_string_lossy().to_string(),
                sync_mode: actual.clone(),
                status: "ok".into(),
            });
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

pub fn unsync_targets(
    id: &str,
    keys: &[String],
    home: &Path,
    targets: &mut Vec<TargetMeta>,
) -> Result<super::target_tx::SyncTransaction, String> {
    let wanted: HashSet<String> = super::sync_plan::dedup(keys).into_iter().collect();
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
    let root = if super::sync_plan::path_exists(&root)? {
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
