use super::*;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "ccbud-skills-{label}-{}-{}-{id}",
            std::process::id(),
            paths::now_ms()
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let name = self.0.file_name().and_then(|v| v.to_str()).unwrap_or("");
        if name.starts_with("ccbud-skills-") {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

fn make_skill(path: &Path, name: &str) {
    std::fs::create_dir_all(path).unwrap();
    std::fs::write(
        path.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: A useful test skill\n---\n\n# {name}\n"),
    )
    .unwrap();
    std::fs::write(path.join("notes.txt"), "hello").unwrap();
}

#[test]
fn scans_only_real_skill_directories() {
    let temp = TempDir::new("scan");
    make_skill(&temp.path().join("one"), "One");
    make_skill(&temp.path().join("group/two"), "Two");
    std::fs::create_dir(temp.path().join("empty")).unwrap();
    let found = scan::local_candidates(temp.path()).unwrap();
    assert_eq!(found.len(), 2);
    assert_eq!(found[0].description.as_deref(), Some("A useful test skill"));
}

#[test]
fn local_import_indexes_tags_and_guards_file_reads() {
    let temp = TempDir::new("import");
    let root = temp.path().join("central");
    let source = temp.path().join("source");
    make_skill(&source, "My Skill");
    let skill = install::import_local(&root, &source).unwrap();
    assert_eq!(skill.id, "my-skill");
    let tagged = catalog::set_tags(
        &root,
        &skill.id,
        vec![" docs ".into(), "docs".into(), "rust".into()],
    )
    .unwrap();
    assert_eq!(tagged.tags, vec!["docs", "rust"]);
    assert_eq!(
        catalog::read_file(&root, &skill.id, "notes.txt").unwrap(),
        "hello"
    );
    assert!(catalog::read_file(&root, &skill.id, "../SKILL.md").is_err());
    assert_eq!(catalog::list(&root).unwrap().len(), 1);
}

#[test]
fn shared_tool_directory_is_created_and_removed_once() {
    let temp = TempDir::new("sync");
    let root = temp.path().join("central");
    let home = temp.path().join("home");
    let source = temp.path().join("source");
    make_skill(&source, "Shared");
    let skill = install::import_local(&root, &source).unwrap();
    let synced = ops::sync(
        &root,
        &home,
        &skill.id,
        vec!["amp".into(), "kimi_cli".into()],
        Some("copy"),
    )
    .unwrap();
    assert_eq!(synced.targets.len(), 2);
    let target = home.join(".config/agents/skills").join(&skill.id);
    assert!(target.join("SKILL.md").is_file());
    let partly = ops::unsync(&root, &home, &skill.id, vec!["amp".into()]).unwrap();
    assert_eq!(partly.targets.len(), 1);
    assert!(target.exists());
    let done = ops::unsync(&root, &home, &skill.id, vec!["kimi_cli".into()]).unwrap();
    assert!(done.targets.is_empty());
    assert!(!target.exists());
}

#[test]
fn tool_matrix_and_shared_project_semantics_match_source() {
    let temp = TempDir::new("tools");
    let tools = tools::list(temp.path());
    assert_eq!(tools.len(), 47);
    let cursor = tools.iter().find(|tool| tool.key == "cursor").unwrap();
    assert_eq!(cursor.project_path.as_deref(), Some(".agents/skills"));
    assert_eq!(cursor.sync_mode, "copy");
    assert!(cursor.shared_project_keys.contains(&"codex".to_string()));
    let amp = tools.iter().find(|tool| tool.key == "amp").unwrap();
    assert!(amp.shared_keys.contains(&"kimi_cli".to_string()));
}

#[test]
fn git_url_and_delete_boundaries_are_rejected() {
    assert!(git::validate_url("https://github.com/example/skill.git").is_ok());
    assert!(git::validate_url("git@github.com:example/skill.git").is_ok());
    assert!(git::validate_url("file:///tmp/repo").is_err());
    assert!(git::validate_url("--upload-pack=evil").is_err());
    let temp = TempDir::new("boundary");
    let root = temp.path().join("root");
    let outside = temp.path().join("outside");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    assert!(paths::remove_direct_child(&root, &outside).is_err());
    assert!(outside.exists());
}
