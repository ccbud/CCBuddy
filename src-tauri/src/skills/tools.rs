use super::model::ToolDto;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug)]
pub struct ToolSpec {
    pub key: &'static str,
    pub label: &'static str,
    pub skills: &'static str,
    pub detect: &'static str,
    pub project: Option<&'static str>,
}

fn all() -> impl Iterator<Item = &'static ToolSpec> {
    super::tool_specs_a::TOOLS
        .iter()
        .chain(super::tool_specs_b::TOOLS.iter())
}

pub fn find(key: &str) -> Option<ToolSpec> {
    all().copied().find(|tool| tool.key == key)
}

pub fn target_root(home: &Path, key: &str) -> Result<PathBuf, String> {
    find(key)
        .map(|tool| home.join(tool.skills))
        .ok_or_else(|| format!("unknown skill tool: {key}"))
}

pub fn list(home: &Path) -> Vec<ToolDto> {
    all()
        .map(|tool| {
            let shared_keys = all()
                .filter(|other| other.skills == tool.skills)
                .map(|other| other.key.to_string())
                .collect();
            let shared_project_keys = tool.project.map_or_else(Vec::new, |project| {
                all()
                    .filter(|other| other.project == Some(project))
                    .map(|other| other.key.to_string())
                    .collect()
            });
            ToolDto {
                key: tool.key.into(),
                label: tool.label.into(),
                path: home.join(tool.skills).to_string_lossy().to_string(),
                detected: home.join(tool.detect).is_dir(),
                enabled: true,
                sync_mode: if tool.key == "cursor" {
                    "copy".into()
                } else {
                    "auto".into()
                },
                shared_keys,
                project_path: tool.project.map(str::to_string),
                shared_project_keys,
            }
        })
        .collect()
}
