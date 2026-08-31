use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SkillsIndex {
    #[serde(default = "index_version")]
    pub version: u32,
    #[serde(default)]
    pub skills: BTreeMap<String, SkillMeta>,
}

impl Default for SkillsIndex {
    fn default() -> Self {
        Self {
            version: index_version(),
            skills: BTreeMap::new(),
        }
    }
}

fn index_version() -> u32 {
    1
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SkillMeta {
    #[serde(default = "local_source")]
    pub source_type: String,
    #[serde(default)]
    pub source_ref: String,
    #[serde(default)]
    pub source_subdir: String,
    #[serde(default)]
    pub source_revision: Option<String>,
    #[serde(default)]
    pub updated_at: i64,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub targets: Vec<TargetMeta>,
    #[serde(default = "ok_status")]
    pub status: String,
}

impl Default for SkillMeta {
    fn default() -> Self {
        Self {
            source_type: local_source(),
            source_ref: String::new(),
            source_subdir: String::new(),
            source_revision: None,
            updated_at: 0,
            tags: Vec::new(),
            targets: Vec::new(),
            status: ok_status(),
        }
    }
}

fn local_source() -> String {
    "local".into()
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct TargetMeta {
    pub key: String,
    pub path: String,
    pub sync_mode: String,
    #[serde(default = "ok_status")]
    pub status: String,
}

fn ok_status() -> String {
    "ok".into()
}

#[derive(Clone, Debug, Serialize)]
pub struct SkillDto {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    pub path: String,
    pub source_type: String,
    pub source_ref: String,
    pub updated_at: i64,
    pub tags: Vec<String>,
    pub targets: Vec<TargetMeta>,
    pub status: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct SkillFileDto {
    pub path: String,
    pub size: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct SkillDetailDto {
    #[serde(flatten)]
    pub skill: SkillDto,
    pub files: Vec<SkillFileDto>,
}

#[derive(Clone, Debug, Serialize)]
pub struct SkillsStatusDto {
    pub root: String,
    pub total: usize,
    pub git_count: usize,
    pub local_count: usize,
    pub synced_count: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct ToolDto {
    pub key: String,
    pub label: String,
    pub path: String,
    pub detected: bool,
    pub enabled: bool,
    pub sync_mode: String,
    pub shared_keys: Vec<String>,
    pub project_path: Option<String>,
    pub shared_project_keys: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct LocalCandidateDto {
    pub name: String,
    pub description: Option<String>,
    pub path: String,
}
