use std::path::{Path, PathBuf};

const MAX_COPY_BYTES: u64 = 512 * 1024 * 1024;
const MAX_COPY_ENTRIES: usize = 30_000;

pub fn slug(value: &str) -> String {
    let mut out = String::new();
    let mut separator = false;
    for c in value.chars() {
        if c.is_alphanumeric() {
            if separator && !out.is_empty() {
                out.push('-');
            }
            out.extend(c.to_lowercase());
            separator = false;
        } else {
            separator = true;
        }
        if out.chars().count() >= 72 {
            break;
        }
    }
    if out.is_empty() {
        "skill".into()
    } else {
        while out.len() > 96 {
            out.pop();
        }
        out
    }
}

pub fn available_id(root: &Path, preferred: &str) -> String {
    let base = slug(preferred);
    if !root.join(&base).exists() {
        return base;
    }
    (2..10_000)
        .map(|n| format!("{base}-{n}"))
        .find(|id| !root.join(id).exists())
        .unwrap_or_else(|| format!("{base}-{}", super::paths::now_ms()))
}

pub fn install_copy(root: &Path, source: &Path, id: &str) -> Result<PathBuf, String> {
    super::paths::validate_id(id)?;
    validate_source(source)?;
    let destination = root.join(id);
    if destination.exists() {
        return Err(format!("skill already exists: {id}"));
    }
    let stage = unique_hidden(root, "stage");
    let result = (|| {
        let mut budget = CopyBudget::default();
        copy_tree(source, &stage, &mut budget, 0)?;
        validate_source(&stage)?;
        std::fs::rename(&stage, &destination).map_err(|e| format!("install skill {id}: {e}"))?;
        Ok(destination.clone())
    })();
    if stage.exists() {
        let _ = super::paths::remove_direct_child(root, &stage);
    }
    result
}

pub fn prepare_replace(
    root: &Path,
    source: &Path,
    id: &str,
) -> Result<(PathBuf, super::target_tx::TargetSwap), String> {
    super::paths::validate_id(id)?;
    validate_source(source)?;
    let destination = root.join(id);
    let swap = super::target_tx::prepare(source, root, &destination, "copy")?;
    Ok((destination, swap))
}

pub fn validate_source(source: &Path) -> Result<(), String> {
    let meta = std::fs::symlink_metadata(source)
        .map_err(|e| format!("inspect source {}: {e}", source.display()))?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err("skill source must be a real directory".into());
    }
    let manifest = source.join("SKILL.md");
    let meta = std::fs::symlink_metadata(&manifest)
        .map_err(|_| format!("missing SKILL.md in {}", source.display()))?;
    if meta.file_type().is_symlink() || !meta.is_file() {
        return Err("SKILL.md must be a regular file".into());
    }
    Ok(())
}

#[derive(Default)]
struct CopyBudget {
    bytes: u64,
    entries: usize,
}

fn copy_tree(
    source: &Path,
    destination: &Path,
    budget: &mut CopyBudget,
    depth: usize,
) -> Result<(), String> {
    if depth > 64 {
        return Err("skill directory nesting is too deep".into());
    }
    std::fs::create_dir(destination)
        .map_err(|e| format!("create {}: {e}", destination.display()))?;
    for entry in std::fs::read_dir(source).map_err(|e| format!("read {}: {e}", source.display()))? {
        let entry = entry.map_err(|e| format!("read source entry: {e}"))?;
        if entry.file_name() == ".git" {
            continue;
        }
        budget.entries += 1;
        if budget.entries > MAX_COPY_ENTRIES {
            return Err("skill contains too many files".into());
        }
        let kind = entry.file_type().map_err(|e| e.to_string())?;
        if kind.is_symlink() {
            return Err(format!(
                "skill contains a symlink: {}",
                entry.path().display()
            ));
        }
        let target = destination.join(entry.file_name());
        if kind.is_dir() {
            copy_tree(&entry.path(), &target, budget, depth + 1)?;
        } else if kind.is_file() {
            let size = entry.metadata().map_err(|e| e.to_string())?.len();
            budget.bytes = budget.bytes.saturating_add(size);
            if budget.bytes > MAX_COPY_BYTES {
                return Err("skill is larger than 512 MiB".into());
            }
            std::fs::copy(entry.path(), &target)
                .map_err(|e| format!("copy {}: {e}", entry.path().display()))?;
        }
    }
    Ok(())
}

pub fn copy_directory(source: &Path, destination: &Path) -> Result<(), String> {
    let mut budget = CopyBudget::default();
    copy_tree(source, destination, &mut budget, 0)
}

pub fn unique_hidden(root: &Path, kind: &str) -> PathBuf {
    let stamp = super::paths::now_ms();
    (0..10_000)
        .map(|n| root.join(format!(".ccbud-{kind}-{stamp}-{n}")))
        .find(|path| !path.exists())
        .unwrap_or_else(|| root.join(format!(".ccbud-{kind}-{stamp}")))
}
