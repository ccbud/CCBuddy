use super::model::{SkillsSyncErrorDto, SyncConflictDto, TargetMeta};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

pub fn sync_conflicts(
    id: &str,
    keys: &[String],
    home: &Path,
    targets: &[TargetMeta],
) -> Result<Vec<SyncConflictDto>, String> {
    super::paths::validate_id(id)?;
    let mut groups = conflict_groups(id, keys, home, targets)?;
    groups.sort_by(|left, right| left.0.cmp(&right.0));
    groups
        .into_iter()
        .map(|(path, keys)| conflict_dto(id, path, keys))
        .collect()
}

pub fn target_expectation(
    id: &str,
    target: &Path,
    keys: &[String],
    home: &Path,
    targets: &[TargetMeta],
    authorizing: &[SyncConflictDto],
) -> Result<super::target_prepare::Expectation, SkillsSyncErrorDto> {
    let conflicts = sync_conflicts(id, keys, home, targets).map_err(SkillsSyncErrorDto::from)?;
    if !conflicts
        .iter()
        .all(|conflict| authorizing.contains(conflict))
    {
        return Err(SkillsSyncErrorDto::ConfirmationRequired { conflicts });
    }
    if let Some(conflict) = conflicts
        .into_iter()
        .find(|conflict| Path::new(&conflict.path) == target)
    {
        return Ok(super::target_prepare::Expectation::Authorized(conflict));
    }
    if targets
        .iter()
        .any(|recorded| Path::new(&recorded.path) == target)
    {
        return Ok(super::target_prepare::Expectation::Unchecked);
    }
    Ok(super::target_prepare::Expectation::Missing)
}

pub fn confirmation_required(
    id: &str,
    keys: &[String],
    home: &Path,
    targets: &[TargetMeta],
) -> SkillsSyncErrorDto {
    match sync_conflicts(id, keys, home, targets) {
        Ok(conflicts) => SkillsSyncErrorDto::ConfirmationRequired { conflicts },
        Err(message) => SkillsSyncErrorDto::Failed { message },
    }
}

pub fn preflight_targets(
    id: &str,
    keys: &[String],
    home: &Path,
    targets: &[TargetMeta],
    authorizing: &[SyncConflictDto],
) -> Result<(), SkillsSyncErrorDto> {
    let conflicts = sync_conflicts(id, keys, home, targets).map_err(SkillsSyncErrorDto::from)?;
    if conflicts.is_empty()
        || (conflicts.len() == authorizing.len()
            && conflicts
                .iter()
                .all(|conflict| authorizing.contains(conflict)))
    {
        Ok(())
    } else {
        Err(SkillsSyncErrorDto::ConfirmationRequired { conflicts })
    }
}

fn conflict_groups(
    id: &str,
    keys: &[String],
    home: &Path,
    targets: &[TargetMeta],
) -> Result<Vec<(PathBuf, Vec<String>)>, String> {
    super::paths::validate_id(id)?;
    let mut groups = Vec::<(PathBuf, Vec<String>)>::new();
    let mut indices = HashMap::<PathBuf, usize>::new();
    for key in dedup(keys) {
        let target = resolved_root(home, &key)?.join(id);
        let tracked = targets.iter().any(|item| Path::new(&item.path) == target);
        if !path_exists(&target)? || tracked {
            continue;
        }
        if let Some(index) = indices.get(&target).copied() {
            groups[index].1.push(key);
        } else {
            indices.insert(target.clone(), groups.len());
            groups.push((target, vec![key]));
        }
    }
    for (_, keys) in &mut groups {
        keys.sort();
    }
    Ok(groups)
}

fn conflict_dto(id: &str, path: PathBuf, keys: Vec<String>) -> Result<SyncConflictDto, String> {
    let fingerprint_token = super::target_fingerprint::confirmation_token(id, &path, &keys)?;
    Ok(SyncConflictDto {
        skill_id: id.into(),
        path: path.to_string_lossy().to_string(),
        keys,
        fingerprint_token,
    })
}

pub fn resolved_root(home: &Path, key: &str) -> Result<PathBuf, String> {
    let root = super::tools::target_root(home, key)?;
    if !path_exists(&root)? {
        return Ok(root);
    }
    if !root.is_dir() {
        return Err(format!(
            "tool skills path is not a directory: {}",
            root.display()
        ));
    }
    root.canonicalize()
        .map_err(|e| format!("resolve tool skills directory: {e}"))
}

pub fn dedup(keys: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    keys.iter()
        .filter(|key| seen.insert((*key).clone()))
        .cloned()
        .collect()
}

pub fn path_exists(path: &Path) -> Result<bool, String> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!("inspect {}: {error}", path.display())),
    }
}
