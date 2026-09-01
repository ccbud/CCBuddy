use super::*;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "ccbud-skills-relocation-{}-{}-{}",
            std::process::id(),
            paths::now_ms(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn make_skill(path: &Path, value: &str) {
    std::fs::create_dir_all(path).unwrap();
    std::fs::write(path.join("SKILL.md"), "---\nname: Guard\n---\n").unwrap();
    std::fs::write(path.join("value.txt"), value).unwrap();
}

#[test]
fn prepare_restores_the_overwrite_target_when_the_stage_changes() {
    let temp = TempDir::new();
    let source = temp.0.join("source");
    let root = temp.0.join("targets");
    let target = root.join("guard");
    make_skill(&source, "managed");
    make_skill(&target, "user-owned");
    let conflict = model::SyncConflictDto {
        skill_id: "guard".into(),
        path: target.to_string_lossy().into_owned(),
        keys: vec!["amp".into()],
        fingerprint_token: target_fingerprint::confirmation_token(
            "guard",
            &target,
            &["amp".into()],
        )
        .unwrap(),
    };
    let released = conflict.clone();
    target_prepare::change_target_during_prepare(8);

    let error = match target_prepare::prepare(
        &source,
        &root,
        &target,
        "copy",
        &target_prepare::Expectation::Authorized(conflict),
    ) {
        Err(error) => error,
        Ok(_) => panic!("changed stage should fail preparation"),
    };

    assert!(matches!(error, target_prepare::PrepareError::Failed(_)));
    assert_eq!(
        std::fs::read_to_string(target.join("value.txt")).unwrap(),
        "user-owned"
    );
    let preserved = root
        .read_dir()
        .unwrap()
        .flatten()
        .find(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".ccbud-sync-stage")
        })
        .unwrap();
    assert_eq!(
        std::fs::read_to_string(preserved.path().join("value.txt")).unwrap(),
        "changed-at-8"
    );
    assert!(!target_fingerprint::matches_confirmation(&released, &target, &target).unwrap());
}

#[test]
fn commit_cleanup_preserves_a_replaced_quarantine_path() {
    let temp = TempDir::new();
    let source = temp.0.join("source");
    let root = temp.0.join("targets");
    let target = root.join("guard");
    make_skill(&source, "managed");
    make_skill(&target, "user-owned");
    let mut swap = target_tx::prepare(&source, &root, &target, "copy").unwrap();
    target_prepare::change_target_during_prepare(7);

    swap.commit();

    let preserved = swap.backup.unwrap();
    assert_eq!(
        std::fs::read_to_string(target.join("value.txt")).unwrap(),
        "managed"
    );
    assert_eq!(
        std::fs::read_to_string(preserved.join("value.txt")).unwrap(),
        "replaced-at-7"
    );
}

#[cfg(unix)]
#[test]
fn pinning_rejects_a_fifo_without_opening_it() {
    use std::os::unix::ffi::OsStrExt;

    let temp = TempDir::new();
    let fifo = temp.0.join("conflict-fifo");
    let path = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);

    let error = target_pin::begin(&fifo).err().unwrap();

    assert!(error.contains("unsupported target filesystem type"));
}

#[test]
fn terminal_commit_failure_releases_transaction_pins() {
    let temp = TempDir::new();
    let source = temp.0.join("source");
    let root = temp.0.join("targets");
    let target = root.join("guard");
    make_skill(&source, "managed");
    make_skill(&target, "user-owned");
    let swap = target_tx::prepare(&source, &root, &target, "copy").unwrap();
    let backup = swap.backup.clone().unwrap();
    let guard = swap.backup_guard.clone().unwrap();
    let mut transaction = target_tx::SyncTransaction::new();
    transaction.push(swap);
    std::fs::write(target.join("value.txt"), "external-edit").unwrap();

    let failure = match transaction.commit() {
        Err(failure) => failure,
        Ok(()) => panic!("tampered target should fail commit"),
    };
    drop(failure);

    assert!(!target_fingerprint::matches_confirmation(&guard, &target, &backup).unwrap());
}

#[cfg(windows)]
#[test]
fn windows_noreplace_move_preserves_an_existing_destination() {
    let temp = TempDir::new();
    let source = temp.0.join("source");
    let destination = temp.0.join("destination");
    make_skill(&source, "source");
    make_skill(&destination, "destination");

    let error = target_stage::install_noreplace(&source, &destination).unwrap_err();

    assert_eq!(error.kind(), std::io::ErrorKind::AlreadyExists);
    assert_eq!(
        std::fs::read_to_string(source.join("value.txt")).unwrap(),
        "source"
    );
    assert_eq!(
        std::fs::read_to_string(destination.join("value.txt")).unwrap(),
        "destination"
    );
}
