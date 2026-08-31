use super::*;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "ccbud-skills-valid-{label}-{}-{}-{id}",
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
        if name.starts_with("ccbud-skills-valid-") {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

fn make_skill(path: &Path, name: &str) {
    std::fs::create_dir_all(path).unwrap();
    std::fs::write(
        path.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: hidden\n---\n"),
    )
    .unwrap();
}

#[test]
fn home_resolution_uses_platform_fallbacks_without_cwd() {
    let temp = TempDir::new("home");
    let profile = temp.0.as_os_str().to_owned();
    assert_eq!(
        paths::resolve_home(None, Some(profile), None, None, true).unwrap(),
        temp.0
    );
    assert!(paths::resolve_home(None, None, None, None, false).is_err());
    assert!(paths::resolve_home(
        Some(OsString::from("relative-home")),
        None,
        None,
        None,
        false
    )
    .is_err());
}

#[test]
fn local_updates_reject_invalid_source_metadata() {
    let temp = TempDir::new("source-meta");
    let root = paths::ensure_root_at(&temp.0.join("central")).unwrap();
    let source = temp.0.join("source");
    make_skill(&source, "Metadata");
    let skill = install::import_local(&root, &source).unwrap();

    set_source(&root, &skill.id, "local", "");
    assert!(
        install::update_source(&root, &temp.0.join("home"), &skill.id)
            .unwrap_err()
            .contains("empty")
    );
    set_source(&root, &skill.id, "unknown", source.to_str().unwrap());
    assert!(
        install::update_source(&root, &temp.0.join("home"), &skill.id)
            .unwrap_err()
            .contains("unsupported source_type")
    );
    set_source(&root, &skill.id, "local", "relative/source");
    assert!(
        install::update_source(&root, &temp.0.join("home"), &skill.id)
            .unwrap_err()
            .contains("absolute")
    );
}

fn set_source(root: &Path, id: &str, source_type: &str, source_ref: &str) {
    let mut value = index::load(root).unwrap();
    let meta = value.skills.get_mut(id).unwrap();
    meta.source_type = source_type.into();
    meta.source_ref = source_ref.into();
    index::save(root, &value).unwrap();
}

#[cfg(unix)]
#[test]
fn central_symlinks_are_reported_invalid_without_following_them() {
    let temp = TempDir::new("central-link");
    let root = paths::ensure_root_at(&temp.0.join("central")).unwrap();
    let source = temp.0.join("source");
    let outside = temp.0.join("outside");
    make_skill(&source, "Managed");
    make_skill(&outside, "External Secret");
    let skill = install::import_local(&root, &source).unwrap();
    paths::remove_direct_child(&root, &root.join(&skill.id)).unwrap();
    std::os::unix::fs::symlink(&outside, root.join(&skill.id)).unwrap();

    let listed = catalog::list(&root).unwrap();
    assert_eq!(listed[0].status, "invalid");
    assert_eq!(listed[0].name, skill.id);
    assert!(catalog::detail(&root, &skill.id).is_err());
    assert!(outside.join("SKILL.md").is_file());
}

#[cfg(unix)]
#[test]
fn central_manifest_symlink_is_reported_invalid() {
    let temp = TempDir::new("manifest-link");
    let root = paths::ensure_root_at(&temp.0.join("central")).unwrap();
    let source = temp.0.join("source");
    let outside = temp.0.join("outside.md");
    make_skill(&source, "Managed");
    std::fs::write(&outside, "# External Secret\n").unwrap();
    let skill = install::import_local(&root, &source).unwrap();
    let manifest = root.join(&skill.id).join("SKILL.md");
    std::fs::remove_file(&manifest).unwrap();
    std::os::unix::fs::symlink(&outside, &manifest).unwrap();

    let listed = catalog::list(&root).unwrap();
    assert_eq!(listed[0].status, "invalid");
    assert_eq!(listed[0].name, skill.id);
    assert!(outside.is_file());
}

#[test]
fn detection_requires_a_tool_directory() {
    let temp = TempDir::new("detect-file");
    std::fs::write(temp.0.join(".cursor"), "not a directory").unwrap();
    let cursor = tools::list(&temp.0)
        .into_iter()
        .find(|tool| tool.key == "cursor")
        .unwrap();
    assert!(!cursor.detected);
}
