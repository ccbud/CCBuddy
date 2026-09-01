use super::model::{SkillDetailDto, SkillDto, SkillMeta, SkillsIndex, SkillsStatusDto};
use std::collections::HashSet;
use std::path::Path;

pub fn list(root: &Path) -> Result<Vec<SkillDto>, String> {
    let _guard = super::index::operation_lock();
    let root = super::paths::ensure_root_at(root)?;
    let mut index = super::index::load(&root)?;
    let changed = reconcile(&root, &mut index)?;
    if changed {
        super::index::save(&root, &index)?;
    }
    list_locked(&root, &index)
}

pub fn detail(root: &Path, id: &str) -> Result<SkillDetailDto, String> {
    let _guard = super::index::operation_lock();
    let root = super::paths::ensure_root_at(root)?;
    let mut index = super::index::load(&root)?;
    if reconcile(&root, &mut index)? {
        super::index::save(&root, &index)?;
    }
    let skill = dto_by_id(&root, &index, id)?;
    let dir = super::paths::existing_skill_dir(&root, id)?;
    let files = super::scan::list_files(&dir)?;
    Ok(SkillDetailDto { skill, files })
}

pub fn read_file(root: &Path, id: &str, file: &str) -> Result<String, String> {
    let dir = super::paths::existing_skill_dir(root, id)?;
    let path = super::paths::safe_file(&dir, file)?;
    let meta = path
        .metadata()
        .map_err(|e| format!("inspect skill file: {e}"))?;
    if meta.len() > 4 * 1024 * 1024 {
        return Err("skill file is too large to preview".into());
    }
    std::fs::read_to_string(&path).map_err(|e| format!("read {}: {e}", path.display()))
}

pub fn status(root: &Path) -> Result<SkillsStatusDto, String> {
    let skills = list(root)?;
    Ok(SkillsStatusDto {
        root: root.to_string_lossy().to_string(),
        total: skills.len(),
        git_count: skills
            .iter()
            .filter(|skill| skill.source_type == "git")
            .count(),
        local_count: skills
            .iter()
            .filter(|skill| skill.source_type != "git")
            .count(),
        synced_count: skills
            .iter()
            .filter(|skill| !skill.targets.is_empty())
            .count(),
    })
}

pub fn refresh(root: &Path, id: Option<&str>) -> Result<Vec<SkillDto>, String> {
    let _guard = super::index::operation_lock();
    let root = super::paths::ensure_root_at(root)?;
    let mut index = super::index::load(&root)?;
    reconcile(&root, &mut index)?;
    if let Some(id) = id {
        super::paths::validate_id(id)?;
        if !index.skills.contains_key(id) {
            return Err(format!("skill not found: {id}"));
        }
    }
    for (skill_id, meta) in &mut index.skills {
        if id.is_some_and(|wanted| wanted != skill_id) || meta.source_type != "git" {
            continue;
        }
        match super::git::remote_head(&meta.source_ref) {
            Ok(head) if meta.source_revision.as_deref() != Some(&head) => {
                meta.status = "update_available".into()
            }
            Ok(_) => meta.status = "ok".into(),
            Err(_) => meta.status = "refresh_error".into(),
        }
    }
    super::index::save(&root, &index)?;
    list_locked(&root, &index)
}

pub fn set_tags(root: &Path, id: &str, values: Vec<String>) -> Result<SkillDto, String> {
    let _guard = super::index::operation_lock();
    let root = super::paths::ensure_root_at(root)?;
    let mut index = super::index::load(&root)?;
    reconcile(&root, &mut index)?;
    let meta = index
        .skills
        .get_mut(id)
        .ok_or_else(|| format!("skill not found: {id}"))?;
    let mut seen = HashSet::new();
    let tags: Vec<String> = values
        .into_iter()
        .map(|tag| tag.trim().to_string())
        .filter(|tag| !tag.is_empty() && tag.chars().count() <= 40 && seen.insert(tag.clone()))
        .take(32)
        .collect();
    meta.tags = tags;
    super::index::save(&root, &index)?;
    dto_by_id(&root, &index, id)
}

pub fn reconcile(root: &Path, index: &mut SkillsIndex) -> Result<bool, String> {
    let mut changed = false;
    for meta in index.skills.values_mut() {
        let target_count = meta.targets.len();
        meta.targets
            .retain(|target| super::tools::find(&target.key).is_some());
        changed |= meta.targets.len() != target_count;
    }
    for (id, path) in super::scan::central_dirs(root)? {
        if !index.skills.contains_key(&id) {
            index.skills.insert(
                id,
                SkillMeta {
                    source_ref: path.to_string_lossy().to_string(),
                    updated_at: super::scan::modified_ms(&path.join("SKILL.md")),
                    ..SkillMeta::default()
                },
            );
            changed = true;
        }
    }
    Ok(changed)
}

pub fn list_locked(root: &Path, index: &SkillsIndex) -> Result<Vec<SkillDto>, String> {
    index
        .skills
        .keys()
        .map(|id| dto_by_id(root, index, id))
        .collect()
}

pub fn dto_by_id(root: &Path, index: &SkillsIndex, id: &str) -> Result<SkillDto, String> {
    super::paths::validate_id(id)?;
    let meta = index
        .skills
        .get(id)
        .ok_or_else(|| format!("skill not found: {id}"))?;
    let path = root.join(id);
    let physical = physical_status(&path);
    let (name, description, physical) = if physical == "ok" {
        match super::scan::manifest_summary(&path) {
            Ok((name, description)) => (name, description, physical),
            Err(_) => (id.to_string(), None, "invalid"),
        }
    } else {
        (id.to_string(), None, physical)
    };
    let mut targets = meta.targets.clone();
    for target in &mut targets {
        if !Path::new(&target.path).exists() {
            target.status = "missing".into();
        }
    }
    let status = if physical != "ok" {
        physical.into()
    } else if targets.iter().any(|target| target.status != "ok") {
        "sync_error".into()
    } else {
        meta.status.clone()
    };
    Ok(SkillDto {
        id: id.into(),
        name,
        description,
        path: path.to_string_lossy().to_string(),
        source_type: meta.source_type.clone(),
        source_ref: meta.source_ref.clone(),
        updated_at: meta.updated_at,
        tags: meta.tags.clone(),
        targets,
        status,
    })
}

fn physical_status(path: &Path) -> &'static str {
    match std::fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => "missing",
        Err(_) => "invalid",
        Ok(meta) if meta.is_dir() && !meta.file_type().is_symlink() => {
            if super::paths::regular_file(&path.join("SKILL.md")) {
                "ok"
            } else {
                "invalid"
            }
        }
        Ok(_) => "invalid",
    }
}
