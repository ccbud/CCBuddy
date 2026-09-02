use super::model::SyncConflictDto;
use std::path::Path;

pub fn confirmation_token(
    skill_id: &str,
    target: &Path,
    keys: &[String],
) -> Result<String, String> {
    pinned_token(skill_id, target, target, keys, false)
}

pub fn matches_confirmation(
    conflict: &SyncConflictDto,
    logical_target: &Path,
    state_path: &Path,
) -> Result<bool, String> {
    let Some((id, expected)) = pinned_parts(&conflict.fingerprint_token) else {
        return Ok(false);
    };
    if !super::target_pin::matches(id, state_path)? {
        return Ok(false);
    }
    let matched = token_at(
        &conflict.skill_id,
        logical_target,
        state_path,
        &conflict.keys,
    )? == expected;
    if !matched {
        return Ok(false);
    }
    super::target_pin::matches(id, state_path)
}

pub fn retoken_after_relocation(
    conflict: &SyncConflictDto,
    logical_target: &Path,
    state_path: &Path,
) -> Result<Option<SyncConflictDto>, String> {
    let refreshed = retoken_confirmation(conflict, logical_target, state_path)?;
    let matched = relocated(&conflict.fingerprint_token) == relocated(&refreshed.fingerprint_token);
    if matched {
        let (id, _) = pinned_parts(&conflict.fingerprint_token).unwrap();
        if !super::target_pin_rotate::active(id, state_path)? {
            return Ok(None);
        }
    }
    Ok(matched.then_some(refreshed))
}

pub fn relocate_noreplace(
    conflict: &SyncConflictDto,
    logical_target: &Path,
    source: &Path,
    destination: &Path,
) -> Result<SyncConflictDto, String> {
    if !matches_confirmation(conflict, logical_target, source)? {
        return Err(format!("relocation source changed: {}", source.display()));
    }
    let (id, _) = pinned_parts(&conflict.fingerprint_token).unwrap();
    let claim = super::target_pin_rotate::claim(id, source)?
        .ok_or_else(|| format!("relocation source changed: {}", source.display()))?;
    #[cfg(test)]
    super::target_pin_rotate_test_hook::after_claim();
    if let Err(error) = super::target_stage::install_noreplace(source, destination) {
        if claim == super::target_pin_rotate::Claim::External {
            super::target_pin_rotate::release(id);
        }
        return Err(format!("relocate {}: {error}", source.display()));
    }
    super::target_prepare_hooks::inject_relocation(source, destination);
    let failure = match retoken_after_relocation(conflict, logical_target, destination) {
        Ok(Some(refreshed)) if claim == super::target_pin_rotate::Claim::Leased => {
            return Ok(refreshed)
        }
        Ok(Some(refreshed)) => match rotate_confirmation(refreshed, destination) {
            Ok(rotated) => return Ok(rotated),
            Err(error) => error,
        },
        Ok(None) => format!("target changed while relocating: {}", destination.display()),
        Err(error) => error,
    };
    let result = match restore_failed_relocation(conflict, logical_target, source, destination) {
        Ok(()) => Err(failure),
        Err(restore) => Err(format!("{failure}; relocation restore failed: {restore}")),
    };
    if claim == super::target_pin_rotate::Claim::External {
        super::target_pin_rotate::release(id);
    }
    result
}

fn rotate_confirmation(
    mut conflict: SyncConflictDto,
    state_path: &Path,
) -> Result<SyncConflictDto, String> {
    let (id, inner) = pinned_parts(&conflict.fingerprint_token)
        .ok_or_else(|| "confirmation guard is not pinned".to_string())?;
    let replacement = super::target_pin_rotate::rotate(id, state_path, inner)?
        .ok_or_else(|| format!("pinned target changed: {}", state_path.display()))?;
    conflict.fingerprint_token = format!("v3:{replacement}:{inner}");
    Ok(conflict)
}

fn restore_failed_relocation(
    seed: &SyncConflictDto,
    logical_target: &Path,
    source: &Path,
    destination: &Path,
) -> Result<(), String> {
    let guard = retoken_confirmation(seed, logical_target, destination)?;
    if std::fs::symlink_metadata(source).is_ok() {
        return Err(format!("source reappeared: {}", source.display()));
    }
    if !matches_confirmation(&guard, logical_target, destination)? {
        return Err(format!("destination changed: {}", destination.display()));
    }
    super::target_stage::install_noreplace(destination, source)
        .map_err(|error| format!("restore {}: {error}", source.display()))?;
    retoken_after_relocation(&guard, logical_target, source)?
        .ok_or_else(|| format!("restored source changed: {}", source.display()))?;
    Ok(())
}

pub fn retoken_confirmation(
    conflict: &SyncConflictDto,
    logical_target: &Path,
    state_path: &Path,
) -> Result<SyncConflictDto, String> {
    let (id, _) = pinned_parts(&conflict.fingerprint_token)
        .ok_or_else(|| "confirmation guard is not pinned".to_string())?;
    if !super::target_pin::matches(id, state_path)? {
        return Err(format!("pinned target changed: {}", state_path.display()));
    }
    let inner = token_at(
        &conflict.skill_id,
        logical_target,
        state_path,
        &conflict.keys,
    )?;
    if !super::target_pin::matches(id, state_path)? {
        return Err(format!("pinned target changed: {}", state_path.display()));
    }
    let mut refreshed = conflict.clone();
    refreshed.fingerprint_token = format!("v3:{id}:{inner}");
    Ok(refreshed)
}

pub fn capture_state(logical_target: &Path, state_path: &Path) -> Result<SyncConflictDto, String> {
    Ok(SyncConflictDto {
        skill_id: String::new(),
        path: logical_target.to_string_lossy().to_string(),
        keys: Vec::new(),
        fingerprint_token: pinned_token("", logical_target, state_path, &[], false)?,
    })
}

pub fn revoke_confirmation(conflict: &SyncConflictDto) {
    if let Some((id, _)) = pinned_parts(&conflict.fingerprint_token) {
        super::target_pin::revoke(id);
    }
}

fn pinned_token(
    skill_id: &str,
    logical_target: &Path,
    state_path: &Path,
    keys: &[String],
    leased: bool,
) -> Result<String, String> {
    let pin = super::target_pin::begin(state_path)?;
    let signature = token_at(skill_id, logical_target, state_path, keys)?;
    let id = pin.finish(state_path, &signature, leased)?;
    Ok(format!("v3:{id}:{signature}"))
}

fn token_at(
    skill_id: &str,
    logical_target: &Path,
    state_path: &Path,
    keys: &[String],
) -> Result<String, String> {
    let tokens = super::target_fingerprint::calculate(skill_id, logical_target, state_path, keys)?;
    Ok(format!("v2:{}:{}", tokens.strict, tokens.relocated))
}

fn relocated(token: &str) -> Option<&str> {
    let (_, inner) = pinned_parts(token)?;
    let value = inner.strip_prefix("v2:")?;
    let (strict, relocated) = value.split_once(':')?;
    (!strict.is_empty() && !relocated.is_empty() && !relocated.contains(':')).then_some(relocated)
}

fn pinned_parts(token: &str) -> Option<(&str, &str)> {
    let value = token.strip_prefix("v3:")?;
    let (id, inner) = value.split_once(':')?;
    (!id.is_empty() && inner.starts_with("v2:")).then_some((id, inner))
}
