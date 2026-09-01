use super::*;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "ccbud-skills-safe-{label}-{}-{}-{id}",
            std::process::id(),
            paths::now_ms()
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let name = self.0.file_name().and_then(|v| v.to_str()).unwrap_or("");
        if name.starts_with("ccbud-skills-safe-") {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

fn make_skill(path: &Path, name: &str, body: &str) {
    std::fs::create_dir_all(path).unwrap();
    std::fs::write(
        path.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: {body}\n---\n"),
    )
    .unwrap();
    std::fs::write(path.join("value.txt"), body).unwrap();
}

fn record_retired_target(root: &Path, id: &str, path: &Path) {
    let mut value = index::load(root).unwrap();
    value.skills.get_mut(id).unwrap().targets = vec![model::TargetMeta {
        key: "retired_tool".into(),
        path: path.to_string_lossy().to_string(),
        sync_mode: "copy".into(),
        status: "ok".into(),
    }];
    index::save(root, &value).unwrap();
}

#[test]
fn index_replaces_existing_file_and_recovers_backup() {
    let temp = TempDir::new("index");
    let root = paths::ensure_root_at(&temp.0.join("root")).unwrap();
    let mut value = model::SkillsIndex::default();
    index::save(&root, &value).unwrap();
    value
        .skills
        .insert("one".into(), model::SkillMeta::default());
    index::save(&root, &value).unwrap();
    assert!(index::load(&root).unwrap().skills.contains_key("one"));
    std::fs::rename(
        root.join(".ccbud-index.json"),
        root.join(".ccbud-index.bak"),
    )
    .unwrap();
    assert!(index::load(&root).unwrap().skills.contains_key("one"));
}

#[test]
fn local_source_update_replaces_managed_copy() {
    let temp = TempDir::new("local-update");
    let root = temp.0.join("root");
    let home = temp.0.join("home");
    let source = temp.0.join("source");
    make_skill(&source, "Local", "before");
    let skill = install::import_local(&root, &source).unwrap();
    make_skill(&source, "Local", "after");
    let updated = install::update_source(&root, &home, &skill.id).unwrap();
    assert_eq!(
        catalog::read_file(&root, &updated.id, "value.txt").unwrap(),
        "after"
    );
}

#[test]
fn reconciled_managed_copy_is_not_treated_as_update_source() {
    let temp = TempDir::new("managed-source");
    let root = temp.0.join("root");
    make_skill(&root.join("manual"), "Manual", "value");
    catalog::list(&root).unwrap();
    let error = install::update_source(&root, &temp.0.join("home"), "manual").unwrap_err();
    assert!(error.contains("no external local source"));
}

#[test]
fn sync_preflight_prevents_partial_targets() {
    let temp = TempDir::new("preflight");
    let root = temp.0.join("root");
    let home = temp.0.join("home");
    let source = temp.0.join("source");
    make_skill(&source, "Safe", "value");
    let skill = install::import_local(&root, &source).unwrap();
    assert!(ops::sync(
        &root,
        &home,
        &skill.id,
        vec!["amp".into(), "unknown".into()],
        Some("copy"),
        vec![],
    )
    .is_err());
    let amp_target = home.join(".config/agents/skills").join(&skill.id);
    assert!(!amp_target.exists());
    let cursor_target = home.join(".cursor/skills").join(&skill.id);
    std::fs::create_dir_all(&cursor_target).unwrap();
    std::fs::write(cursor_target.join("user.txt"), "keep").unwrap();
    assert!(ops::sync(
        &root,
        &home,
        &skill.id,
        vec!["amp".into(), "cursor".into()],
        Some("copy"),
        vec![],
    )
    .is_err());
    assert!(!amp_target.exists());
    assert!(cursor_target.join("user.txt").exists());
}

#[cfg(unix)]
#[test]
fn failed_revision_probe_cleans_git_checkout() {
    use std::os::unix::fs::PermissionsExt;
    let temp = TempDir::new("git-cleanup");
    let root = paths::ensure_root_at(&temp.0.join("root")).unwrap();
    let program = temp.0.join("fake-git.sh");
    std::fs::write(
        &program,
        "#!/bin/sh\nif [ \"$1\" = clone ]; then\n for last; do :; done\n mkdir -p \"$last\"\n exit 0\nfi\nexit 1\n",
    )
    .unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(
        git::clone_with_test_program(&root, "https://github.com/example/skill.git", &program)
            .is_err()
    );
    assert!(
        !std::fs::read_dir(root).unwrap().flatten().any(|entry| entry
            .file_name()
            .to_string_lossy()
            .starts_with(".ccbud-git-"))
    );
}

#[test]
fn list_persists_retired_target_removal_without_touching_physical_path() {
    let temp = TempDir::new("retired-list");
    let root = temp.0.join("root");
    let home = temp.0.join("home");
    let source = temp.0.join("source");
    make_skill(&source, "Retired List", "managed");
    let skill = install::import_local(&root, &source).unwrap();
    let orphan = home.join(".retired/skills").join(&skill.id);
    make_skill(&orphan, "Retired Physical", "keep");
    record_retired_target(&root, &skill.id, &orphan);

    let listed = catalog::list(&root).unwrap();
    assert!(listed[0].targets.is_empty());
    assert!(index::load(&root).unwrap().skills[&skill.id]
        .targets
        .is_empty());
    assert_eq!(
        std::fs::read_to_string(orphan.join("value.txt")).unwrap(),
        "keep"
    );
}

#[test]
fn update_and_delete_reconcile_retired_targets_without_touching_physical_path() {
    let temp = TempDir::new("retired-mutations");
    let root = temp.0.join("root");
    let home = temp.0.join("home");
    let source = temp.0.join("source");
    make_skill(&source, "Retired Mutation", "before");
    let skill = install::import_local(&root, &source).unwrap();
    let orphan = home.join(".retired/skills").join(&skill.id);
    make_skill(&orphan, "Retired Physical", "keep");
    record_retired_target(&root, &skill.id, &orphan);
    make_skill(&source, "Retired Mutation", "after");

    let updated = install::update_source(&root, &home, &skill.id).unwrap();
    assert!(updated.targets.is_empty());
    assert_eq!(
        catalog::read_file(&root, &skill.id, "value.txt").unwrap(),
        "after"
    );
    assert_eq!(
        std::fs::read_to_string(orphan.join("value.txt")).unwrap(),
        "keep"
    );

    record_retired_target(&root, &skill.id, &orphan);
    assert!(remove::delete(&root, &home, &skill.id).unwrap());
    assert!(!root.join(&skill.id).exists());
    assert_eq!(
        std::fs::read_to_string(orphan.join("value.txt")).unwrap(),
        "keep"
    );
}
