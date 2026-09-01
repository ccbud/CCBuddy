use super::model::{LocalCandidateDto, SkillFileDto};
use std::path::{Path, PathBuf};

const MAX_SCAN_DEPTH: usize = 12;
const MAX_ENTRIES: usize = 20_000;

pub fn central_dirs(root: &Path) -> Result<Vec<(String, PathBuf)>, String> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(root).map_err(|e| format!("scan {}: {e}", root.display()))? {
        let entry = entry.map_err(|e| format!("scan skills entry: {e}"))?;
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') || super::paths::validate_id(&name).is_err() {
            continue;
        }
        let meta = entry
            .file_type()
            .map_err(|e| format!("inspect {}: {e}", entry.path().display()))?;
        if meta.is_dir()
            && !meta.is_symlink()
            && super::paths::regular_file(&entry.path().join("SKILL.md"))
        {
            out.push((name, entry.path()));
        }
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

pub fn local_candidates(path: &Path) -> Result<Vec<LocalCandidateDto>, String> {
    let base = path
        .canonicalize()
        .map_err(|e| format!("resolve local path {}: {e}", path.display()))?;
    if !base.is_dir() {
        return Err("local source must be a directory".into());
    }
    let mut dirs = Vec::new();
    let mut seen = 0usize;
    walk_candidates(&base, 0, &mut seen, &mut dirs)?;
    dirs.sort();
    dirs.into_iter()
        .map(|dir| {
            let (name, description) = manifest_summary(&dir)?;
            Ok(LocalCandidateDto {
                name,
                description,
                path: dir.to_string_lossy().to_string(),
            })
        })
        .collect()
}

fn walk_candidates(
    dir: &Path,
    depth: usize,
    seen: &mut usize,
    out: &mut Vec<PathBuf>,
) -> Result<(), String> {
    if depth > MAX_SCAN_DEPTH || *seen > MAX_ENTRIES {
        return Err("skill scan limit exceeded".into());
    }
    if dir.join("SKILL.md").is_file() {
        out.push(dir.to_path_buf());
        return Ok(());
    }
    for entry in std::fs::read_dir(dir).map_err(|e| format!("scan {}: {e}", dir.display()))? {
        let entry = entry.map_err(|e| format!("scan local entry: {e}"))?;
        *seen += 1;
        if *seen > MAX_ENTRIES {
            return Err("skill scan limit exceeded".into());
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if ignored_dir(&name) {
            continue;
        }
        let kind = entry
            .file_type()
            .map_err(|e| format!("inspect {}: {e}", entry.path().display()))?;
        if kind.is_dir() && !kind.is_symlink() {
            walk_candidates(&entry.path(), depth + 1, seen, out)?;
        }
    }
    Ok(())
}

fn ignored_dir(name: &str) -> bool {
    name.starts_with(".ccbud") || matches!(name, ".git" | "node_modules" | "target")
}

pub fn manifest_summary(dir: &Path) -> Result<(String, Option<String>), String> {
    let path = dir.join("SKILL.md");
    if !super::paths::regular_file(&path) {
        return Err(format!(
            "SKILL.md is not a regular file: {}",
            path.display()
        ));
    }
    let bytes = std::fs::read(&path).map_err(|e| format!("read {}: {e}", path.display()))?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err(format!("SKILL.md is too large: {}", path.display()));
    }
    let text = String::from_utf8(bytes).map_err(|_| "SKILL.md must be UTF-8".to_string())?;
    let fallback = dir
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("skill")
        .to_string();
    let mut name = None;
    let mut description = None;
    let mut body_start = 0usize;
    let lines: Vec<&str> = text.lines().collect();
    if lines.first().is_some_and(|line| line.trim() == "---") {
        for (idx, line) in lines.iter().enumerate().skip(1) {
            if line.trim() == "---" {
                body_start = idx + 1;
                break;
            }
            if let Some(value) = line.strip_prefix("name:") {
                name = clean_scalar(value);
            } else if let Some(value) = line.strip_prefix("description:") {
                description = clean_scalar(value);
            }
        }
    }
    if name.is_none() {
        name = lines[body_start..]
            .iter()
            .find_map(|line| line.trim().strip_prefix("# ").map(str::to_string));
    }
    if description.is_none() {
        description = lines[body_start..]
            .iter()
            .map(|line| line.trim())
            .find(|line| !line.is_empty() && !line.starts_with('#'))
            .map(|line| line.chars().take(240).collect());
    }
    Ok((
        name.filter(|s| !s.is_empty()).unwrap_or(fallback),
        description,
    ))
}

fn clean_scalar(value: &str) -> Option<String> {
    let value = value.trim().trim_matches(|c| c == '\'' || c == '"');
    (!value.is_empty() && value != ">" && value != "|").then(|| value.to_string())
}

pub fn list_files(dir: &Path) -> Result<Vec<SkillFileDto>, String> {
    let mut out = Vec::new();
    let mut seen = 0usize;
    walk_files(dir, dir, 0, &mut seen, &mut out)?;
    out.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(out)
}

fn walk_files(
    base: &Path,
    dir: &Path,
    depth: usize,
    seen: &mut usize,
    out: &mut Vec<SkillFileDto>,
) -> Result<(), String> {
    if depth > MAX_SCAN_DEPTH || *seen > MAX_ENTRIES {
        return Err("skill file listing limit exceeded".into());
    }
    for entry in std::fs::read_dir(dir).map_err(|e| format!("list {}: {e}", dir.display()))? {
        let entry = entry.map_err(|e| format!("list skill entry: {e}"))?;
        *seen += 1;
        if *seen > MAX_ENTRIES {
            return Err("skill file listing limit exceeded".into());
        }
        let kind = entry.file_type().map_err(|e| e.to_string())?;
        if kind.is_symlink() || entry.file_name() == ".git" {
            continue;
        }
        if kind.is_dir() {
            walk_files(base, &entry.path(), depth + 1, seen, out)?;
        } else if kind.is_file() {
            let path = entry.path();
            let relative = path
                .strip_prefix(base)
                .map_err(|_| "invalid skill file".to_string())?;
            out.push(SkillFileDto {
                path: relative.to_string_lossy().replace('\\', "/"),
                size: entry.metadata().map_err(|e| e.to_string())?.len(),
            });
        }
    }
    Ok(())
}

pub fn modified_ms(path: &Path) -> i64 {
    path.metadata()
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or_else(super::paths::now_ms)
}
