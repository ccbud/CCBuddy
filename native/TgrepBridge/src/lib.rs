//! A narrow in-process ABI around upstream tgrep. No shell, server, telemetry,
//! producer-file traversal, or original transcript copies are involved.
//!
//! The caller supplies canonical, case-folded UTF-8 documents and stable SQLite
//! IDs. Only trigrams and numeric IDs reach the private temporary disk index.
//! The live overlay is flushed every 64 MiB of input; streaming merges keep the
//! full corpus's postings in mmap instead of a second in-memory transcript store.

use std::cell::Cell;
use std::collections::HashSet;
use std::ffi::c_void;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::fs::PermissionsExt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::slice;
use tgrep_core::builder::{append_overlay_to_index, merge_index_with_delta};
use tgrep_core::hybrid::HybridIndex;
use tgrep_core::live::LiveIndex;
use tgrep_core::query::build_literal_plan;
use tgrep_core::reader::IndexReader;

const FLUSH_BYTES: usize = 64 * 1024 * 1024;
thread_local! {
    // Additive ABI-v2 diagnostic. Numeric codes cannot expose transcript text,
    // query strings, cache paths, or raw operating-system error descriptions.
    static LAST_ERROR_CODE: Cell<u32> = const { Cell::new(0) };
}

#[derive(Debug)]
struct UnsafeCache;

impl std::fmt::Display for UnsafeCache {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("unsafe cache")
    }
}
impl std::error::Error for UnsafeCache {}

fn error_code(mut error: &(dyn std::error::Error + 'static)) -> u32 {
    let mut saw_io_error = false;
    loop {
        if error.is::<UnsafeCache>() {
            return 3;
        }
        if let Some(io) = error.downcast_ref::<std::io::Error>() {
            saw_io_error = true;
            if matches!(io.raw_os_error(), Some(libc::ENOSPC) | Some(libc::EDQUOT)) {
                return 1;
            }
            if let Some(inner) = io.get_ref() {
                error = inner;
                continue;
            }
        }
        match error.source() {
            Some(source) => error = source,
            None => return if saw_io_error { 2 } else { 4 },
        }
    }
}

fn ffi_result<T>(fallback: T, body: impl FnOnce() -> Result<T, Box<dyn std::error::Error>>) -> T {
    LAST_ERROR_CODE.set(0);
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => {
            LAST_ERROR_CODE.set(error_code(error.as_ref()));
            fallback
        }
        Err(_) => {
            LAST_ERROR_CODE.set(4);
            fallback
        }
    }
}
const CHECKPOINT_FILES: [&str; 4] = [
    "lookup.bin",
    "index.bin",
    "files.bin",
    "ccbuddy-manifest.json",
];

fn checkpoint_checksums(directory: &Path) -> std::io::Result<String> {
    let mut checksums = String::new();
    let mut buffer = [0u8; 64 * 1024];
    for name in CHECKPOINT_FILES {
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(directory.join(name))?;
        if !file.metadata()?.is_file() {
            return Err(std::io::Error::other("unsafe checkpoint file"));
        }
        let mut hasher = blake3::Hasher::new();
        loop {
            let read = file.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
        }
        checksums.push_str(&format!("{name} {}\n", hasher.finalize().to_hex()));
    }
    Ok(checksums)
}

fn read_small_regular_file(path: &Path, limit: u64) -> std::io::Result<Vec<u8>> {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > limit {
        return Err(std::io::Error::other("unsafe checkpoint metadata"));
    }
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(std::io::Error::other("oversized checkpoint metadata"));
    }
    Ok(bytes)
}

struct Engine {
    index: HybridIndex,
    directory: tempfile::TempDir,
    pending_bytes: usize,
    sequence: u64,
    active_directory: Option<std::path::PathBuf>,
    persistent_root: Option<PathBuf>,
    checkpoint: Option<PathBuf>,
    manifest: Vec<u8>,
    _lease: Option<std::fs::File>,
}

impl Engine {
    fn new() -> Result<Self, Box<dyn std::error::Error>> {
        Self::new_in(None)
    }

    fn new_in(parent: Option<&Path>) -> Result<Self, Box<dyn std::error::Error>> {
        // Harden before any postings are written; no history paths or query
        // text are used in its name. It is removed when the database closes.
        let mut builder = tempfile::Builder::new();
        builder.prefix("ccbuddy-tgrep-");
        let directory = match parent {
            Some(parent) => builder.tempdir_in(parent)?,
            None => builder.tempdir()?,
        };
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))?;
        let initial = directory.path().join("index-0");
        append_overlay_to_index(
            directory.path(),
            &initial,
            &IndexReader::empty(),
            &[],
            &Default::default(),
            true,
        )?;
        let index = HybridIndex::open(&initial, directory.path())?;
        Ok(Self {
            index,
            directory,
            pending_bytes: 0,
            sequence: 0,
            active_directory: Some(initial),
            persistent_root: None,
            checkpoint: None,
            manifest: Vec::new(),
            _lease: None,
        })
    }

    fn persistent(root: &Path) -> Result<Self, Box<dyn std::error::Error>> {
        if let Ok(metadata) = std::fs::symlink_metadata(root) {
            if !metadata.is_dir() || metadata.file_type().is_symlink() {
                return Err(UnsafeCache.into());
            }
        } else {
            std::fs::create_dir_all(root)?;
        }
        std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700))?;
        let lease = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(root.join("lock"))?;
        let owns_lease =
            unsafe { libc::flock(lease.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0;
        let mut engine = Self::new_in(Some(root))?;
        if !owns_lease {
            // Another database instance can use an isolated overlay on the same
            // volume without racing publication of the persistent checkpoint.
            return Ok(engine);
        }
        engine._lease = Some(lease);
        engine.persistent_root = Some(root.to_owned());
        if let Ok(pointer) = read_small_regular_file(&root.join("active"), 128) {
            let name = String::from_utf8_lossy(&pointer);
            let name = name.trim();
            if name.starts_with("checkpoint-")
                && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            {
                let checkpoint = root.join(name);
                let safe = std::fs::symlink_metadata(&checkpoint)
                    .is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink())
                    && std::fs::read_dir(&checkpoint).is_ok_and(|entries| {
                        entries.flatten().all(|entry| {
                            entry
                                .file_type()
                                .is_ok_and(|kind| kind.is_file() && !kind.is_symlink())
                        })
                    });
                let intact = safe
                    && checkpoint_checksums(&checkpoint).is_ok_and(|checksums| {
                        read_small_regular_file(&checkpoint.join("ccbuddy-checksums"), 1024)
                            .is_ok_and(|stored| stored == checksums.as_bytes())
                    });
                if intact {
                    engine.checkpoint = Some(checkpoint.clone());
                    if let Ok(index) = HybridIndex::open(&checkpoint, root) {
                        if let Ok(metadata) =
                            std::fs::metadata(checkpoint.join("ccbuddy-manifest.json"))
                        {
                            if metadata.len() <= 16 * 1024 * 1024 {
                                engine.manifest =
                                    std::fs::read(checkpoint.join("ccbuddy-manifest.json"))
                                        .unwrap_or_default();
                                engine.index = index;
                                engine.active_directory = None;
                            }
                        }
                    }
                }
            }
        }
        Ok(engine)
    }

    fn persist(&mut self, manifest: &[u8]) -> Result<(), Box<dyn std::error::Error>> {
        let Some(root) = &self.persistent_root else {
            return Ok(());
        };
        let source = self
            .active_directory
            .as_ref()
            .or(self.checkpoint.as_ref())
            .ok_or_else(|| std::io::Error::other("missing checkpoint source"))?;
        let output = tempfile::Builder::new()
            .prefix("checkpoint-")
            .tempdir_in(root)?;
        std::fs::set_permissions(output.path(), std::fs::Permissions::from_mode(0o700))?;
        // The reader needs only these three binary files. In particular, do
        // not retain upstream meta.json, whose root_path is a working-cache
        // location rather than searchable data or a necessary reader input.
        for name in ["lookup.bin", "index.bin", "files.bin"] {
            if !std::fs::symlink_metadata(source.join(name))?
                .file_type()
                .is_file()
            {
                return Err(std::io::Error::other("unsafe index file").into());
            }
            // Completed tgrep files are immutable. Hard links publish a sealed
            // checkpoint without copying the entire postings index again.
            std::fs::hard_link(source.join(name), output.path().join(name))?;
        }
        let mut manifest_file = std::fs::File::create(output.path().join("ccbuddy-manifest.json"))?;
        manifest_file.write_all(manifest)?;
        manifest_file.sync_all()?;
        let mut integrity = std::fs::File::create(output.path().join("ccbuddy-checksums"))?;
        integrity.write_all(checkpoint_checksums(output.path())?.as_bytes())?;
        integrity.sync_all()?;
        // Flush data before publishing the directory entry. A kill between
        // these steps leaves the old sealed checkpoint authoritative.
        for name in CHECKPOINT_FILES {
            std::fs::File::open(output.path().join(name))?.sync_all()?;
        }
        std::fs::File::open(output.path())?.sync_all()?;
        let mut pointer = tempfile::NamedTempFile::new_in(root)?;
        pointer.write_all(output.path().file_name().unwrap().as_encoded_bytes())?;
        pointer.as_file().sync_all()?;
        pointer.persist(root.join("active"))?;
        let output = output.keep();
        std::fs::File::open(root)?.sync_all()?;
        self.manifest = manifest.to_vec();
        self.checkpoint = Some(output.clone());
        // Only the lifetime-lease owner publishes checkpoints. Reclaim its
        // abandoned/corrupt sealed directories after durable publication, but
        // never touch another instance's live ccbuddy-tgrep-* workspace.
        for entry in std::fs::read_dir(root)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if entry.path() != output
                && name.starts_with("checkpoint-")
                && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                && entry.file_type()?.is_dir()
            {
                let _ = std::fs::remove_dir_all(entry.path());
            }
        }
        Ok(())
    }

    fn upsert(&mut self, id: i64, text: &[u8]) -> Result<(), Box<dyn std::error::Error>> {
        // Upstream's mask-free bulk path avoids a per-(trigram, document) mask
        // map. Candidate verification stays in Foundation, so masks are optional.
        // The basic extract() helper uses SipHash once per input byte. Upstream's
        // merged extractor uses its purpose-built multiply/xorshift trigram
        // hasher; keeping only its keys retains the bounded mask-free overlay.
        let trigrams = tgrep_core::trigram::extract_merged_masks(text)
            .into_keys()
            .collect();
        self.index
            .live
            .upsert_file_with_trigrams(&id.to_string(), trigrams);
        self.pending_bytes = self.pending_bytes.saturating_add(text.len());
        if self.pending_bytes >= FLUSH_BYTES {
            self.flush()?;
        }
        Ok(())
    }

    fn retain(&mut self, ids: &[i64]) {
        let retained: HashSet<String> = ids.iter().map(i64::to_string).collect();
        for path in self.index.all_paths() {
            if !retained.contains(&path) {
                self.index.live.delete_file(&path);
            }
        }
    }

    fn flush(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        if !self.index.live.has_pending_changes() {
            return Ok(());
        }
        self.sequence += 1;
        let output = self
            .directory
            .path()
            .join(format!("index-{}", self.sequence));
        let delta = self
            .directory
            .path()
            .join(format!("delta-{}", self.sequence));
        let (paths, inverted) = self.index.live.snapshot_for_disk();
        let reader = self.index.reader_arc();
        let mut removed: HashSet<String> = self.index.live.tombstone_paths().into_iter().collect();
        removed.extend(
            paths
                .iter()
                .filter(|path| reader.contains_path(path))
                .cloned(),
        );
        if removed.is_empty() {
            append_overlay_to_index(
                self.directory.path(),
                &output,
                &reader,
                &paths,
                &inverted,
                true,
            )?;
        } else {
            append_overlay_to_index(
                self.directory.path(),
                &delta,
                &IndexReader::empty(),
                &paths,
                &inverted,
                true,
            )?;
            let delta_reader = IndexReader::open(&delta)?;
            merge_index_with_delta(
                self.directory.path(),
                &output,
                &reader,
                &delta_reader,
                &removed,
                true,
            )?;
        }
        let replacement = IndexReader::open(&output)?;
        replacement
            .validate_lookup()
            .map_err(std::io::Error::other)?;
        self.index.swap_reader(replacement);
        self.index.live = LiveIndex::new();
        self.pending_bytes = 0;
        drop(reader);
        // Targets are exclusively directories created by this Engine in its
        // private TempDir. No user-provided path can reach a removal operation.
        if let Some(previous) = self.active_directory.replace(output) {
            let _ = std::fs::remove_dir_all(previous);
        }
        if delta.exists() {
            let _ = std::fs::remove_dir_all(delta);
        }
        Ok(())
    }

    fn search(&self, query: &str) -> Vec<i64> {
        let plan = build_literal_plan(query, false);
        let mut ids: Vec<i64> = self
            .index
            .execute_query(&plan)
            .into_iter()
            .filter_map(|id| self.index.file_path(id)?.parse().ok())
            .collect();
        ids.sort_unstable();
        ids.dedup();
        ids
    }
}

/// ABI v2 adds atomically published persistent checkpoints.
#[unsafe(no_mangle)]
pub extern "C" fn ccbuddy_tgrep_abi_version() -> u32 {
    2
}

/// Last failure on the calling thread: 0 none, 1 disk/quota full, 2 I/O,
/// 3 unsafe cache, 4 other. Read immediately after a failed ABI call.
#[unsafe(no_mangle)]
pub extern "C" fn ccbuddy_tgrep_last_error_code() -> u32 {
    LAST_ERROR_CODE.get()
}

#[unsafe(no_mangle)]
pub extern "C" fn ccbuddy_tgrep_create() -> *mut c_void {
    ffi_result(std::ptr::null_mut(), || {
        Ok(Box::into_raw(Box::new(Engine::new()?)).cast())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ccbuddy_tgrep_create_persistent(
    bytes: *const u8,
    length: usize,
) -> *mut c_void {
    if bytes.is_null() {
        LAST_ERROR_CODE.set(4);
        return std::ptr::null_mut();
    }
    ffi_result(std::ptr::null_mut(), || {
        let path = std::str::from_utf8(unsafe { slice::from_raw_parts(bytes, length) })?;
        Ok(Box::into_raw(Box::new(Engine::persistent(Path::new(path))?)).cast())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ccbuddy_tgrep_copy_manifest(
    engine: *mut c_void,
    output: *mut u8,
    capacity: usize,
) -> isize {
    if engine.is_null() || (output.is_null() && capacity != 0) {
        LAST_ERROR_CODE.set(4);
        return -1;
    }
    ffi_result(-1, || {
        let manifest = &unsafe { &*engine.cast::<Engine>() }.manifest;
        if manifest.len() <= capacity && !manifest.is_empty() {
            unsafe {
                std::ptr::copy_nonoverlapping(manifest.as_ptr(), output, manifest.len());
            }
        }
        Ok(isize::try_from(manifest.len())?)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ccbuddy_tgrep_persist(
    engine: *mut c_void,
    bytes: *const u8,
    length: usize,
) -> i32 {
    if engine.is_null() || bytes.is_null() || length > 16 * 1024 * 1024 {
        LAST_ERROR_CODE.set(4);
        return -1;
    }
    ffi_result(-1, || {
        let engine = unsafe { &mut *engine.cast::<Engine>() };
        let manifest = unsafe { slice::from_raw_parts(bytes, length) };
        engine.persist(manifest)?;
        Ok(0)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ccbuddy_tgrep_destroy(engine: *mut c_void) {
    if !engine.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(engine.cast::<Engine>()));
        }));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ccbuddy_tgrep_upsert(
    engine: *mut c_void,
    id: i64,
    bytes: *const u8,
    length: usize,
) -> i32 {
    if engine.is_null() || bytes.is_null() {
        LAST_ERROR_CODE.set(4);
        return -1;
    }
    ffi_result(-1, || {
        let engine = unsafe { &mut *engine.cast::<Engine>() };
        let text = unsafe { slice::from_raw_parts(bytes, length) };
        engine.upsert(id, text)?;
        Ok(0)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ccbuddy_tgrep_retain(
    engine: *mut c_void,
    ids: *const i64,
    count: usize,
) -> i32 {
    if engine.is_null() || (ids.is_null() && count != 0) {
        LAST_ERROR_CODE.set(4);
        return -1;
    }
    ffi_result(-1, || {
        let engine = unsafe { &mut *engine.cast::<Engine>() };
        let ids = if count == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(ids, count) }
        };
        engine.retain(ids);
        engine.flush()?;
        Ok(0)
    })
}

/// Caller owns `output`; return the required capacity, or -1 on failure. Calls
/// are serialized by the catalog read lock, so a capacity retry is consistent.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ccbuddy_tgrep_query(
    engine: *mut c_void,
    bytes: *const u8,
    length: usize,
    output: *mut i64,
    capacity: usize,
) -> isize {
    if engine.is_null() || bytes.is_null() || (output.is_null() && capacity != 0) {
        LAST_ERROR_CODE.set(4);
        return -1;
    }
    ffi_result(-1, || {
        let engine = unsafe { &*engine.cast::<Engine>() };
        let query = std::str::from_utf8(unsafe { slice::from_raw_parts(bytes, length) })?;
        let ids = engine.search(query);
        if ids.len() <= capacity && !ids.is_empty() {
            unsafe {
                std::ptr::copy_nonoverlapping(ids.as_ptr(), output, ids.len());
            }
        }
        Ok(isize::try_from(ids.len())?)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failure_codes_are_sanitized_and_success_clears_them() {
        for (errno, code) in [(libc::ENOSPC, 1), (libc::EDQUOT, 1), (libc::EACCES, 2)] {
            let result = ffi_result(-1, || Err(std::io::Error::from_raw_os_error(errno).into()));
            assert_eq!(result, -1);
            assert_eq!(ccbuddy_tgrep_last_error_code(), code);
            assert_eq!(
                error_code(&std::io::Error::other(std::io::Error::from_raw_os_error(
                    errno
                ))),
                code
            );
        }
        assert_eq!(ffi_result(-1, || Ok(0)), 0);
        assert_eq!(ccbuddy_tgrep_last_error_code(), 0);
    }

    #[test]
    fn persistent_abi_reports_unsafe_root_without_exposing_the_path() {
        let root = tempfile::tempdir().unwrap();
        let blocked = root.path().join("private-sentinel-root");
        std::fs::write(&blocked, b"untouched").unwrap();
        let path = blocked.as_os_str().as_encoded_bytes();
        let handle = unsafe { ccbuddy_tgrep_create_persistent(path.as_ptr(), path.len()) };
        assert!(handle.is_null());
        assert_eq!(ccbuddy_tgrep_last_error_code(), 3);
        assert_eq!(std::fs::read(blocked).unwrap(), b"untouched");
    }

    #[test]
    fn failure_diagnostics_are_thread_local() {
        LAST_ERROR_CODE.set(1);
        std::thread::spawn(|| {
            assert_eq!(ccbuddy_tgrep_last_error_code(), 0);
            LAST_ERROR_CODE.set(2);
        })
        .join()
        .unwrap();
        assert_eq!(ccbuddy_tgrep_last_error_code(), 1);
    }

    #[test]
    fn literal_candidates_cover_unicode_spaces_nuls_and_punctuation() {
        let mut engine = Engine::new().unwrap();
        engine
            .upsert(11, "二维码搜索 useeffect( foo bar a\0b".as_bytes())
            .unwrap();
        engine.upsert(12, b"unrelated contents").unwrap();
        engine.flush().unwrap();
        for query in ["二维码", "码", "useeffect(", "foo bar", "a\0b"] {
            assert_eq!(engine.search(query), vec![11], "{query}");
        }
        assert_eq!(engine.search("absent"), Vec::<i64>::new());
        assert_eq!(engine.search("a"), vec![11, 12]); // short-query superset
    }

    #[test]
    fn disk_overlay_replacement_deletion_and_id_reuse_do_not_return_stale_rows() {
        let mut engine = Engine::new().unwrap();
        engine.upsert(1, b"old needle").unwrap();
        engine.upsert(2, b"old needle").unwrap();
        engine.flush().unwrap();
        engine.upsert(1, b"new replacement").unwrap();
        assert_eq!(engine.search("old"), vec![2]);
        engine.retain(&[1]);
        engine.flush().unwrap();
        assert!(engine.search("old").is_empty());
        assert_eq!(engine.search("replacement"), vec![1]);
        engine.upsert(2, b"reused identity").unwrap();
        engine.flush().unwrap();
        assert_eq!(engine.search("reused"), vec![2]);
        engine.retain(&[]);
        engine.flush().unwrap();
        assert!(engine.search("replacement").is_empty());
    }

    #[test]
    fn private_cache_contains_numeric_ids_and_postings_only_and_is_removed_on_drop() {
        use std::os::unix::fs::PermissionsExt;
        let mut engine = Engine::new().unwrap();
        let root = engine.directory.path().to_owned();
        assert_eq!(
            std::fs::metadata(&root).unwrap().permissions().mode() & 0o777,
            0o700
        );
        engine
            .upsert(72, b"sensitive-transcript-sentinel-long-text")
            .unwrap();
        engine.flush().unwrap();
        let cache = engine.active_directory.as_ref().unwrap();
        let sentinel = b"sensitive-transcript-sentinel-long-";
        for entry in std::fs::read_dir(cache).unwrap() {
            let bytes = std::fs::read(entry.unwrap().path()).unwrap();
            assert!(
                !bytes
                    .windows(sentinel.len())
                    .any(|window| window == sentinel)
            );
        }
        drop(engine);
        assert!(!root.exists());
    }

    #[test]
    fn checkpoint_survives_reopen_and_unpublished_work_cannot_replace_it() {
        let root = tempfile::tempdir().unwrap();
        {
            let mut engine = Engine::persistent(root.path()).unwrap();
            engine.upsert(1, b"stable committed value").unwrap();
            engine.flush().unwrap();
            engine.persist(b"manifest-one").unwrap();
            engine.upsert(1, b"unpublished replacement").unwrap();
            engine.flush().unwrap(); // crash before manifest/pointer publication
        }
        let mut reopened = Engine::persistent(root.path()).unwrap();
        assert_eq!(reopened.manifest, b"manifest-one");
        assert_eq!(reopened.search("committed"), vec![1]);
        assert!(reopened.search("unpublished").is_empty());
        reopened.upsert(1, b"published replacement").unwrap();
        reopened.flush().unwrap();
        reopened.persist(b"manifest-two").unwrap();
        drop(reopened);
        let latest = Engine::persistent(root.path()).unwrap();
        assert_eq!(latest.manifest, b"manifest-two");
        assert_eq!(latest.search("published replacement"), vec![1]);
        assert!(latest.search("committed").is_empty());
    }

    #[test]
    fn concurrent_instances_cannot_overwrite_each_others_checkpoint() {
        let root = tempfile::tempdir().unwrap();
        let mut owner = Engine::persistent(root.path()).unwrap();
        owner.upsert(1, b"owner checkpoint").unwrap();
        owner.flush().unwrap();
        owner.persist(b"owner").unwrap();
        let mut concurrent = Engine::persistent(root.path()).unwrap();
        assert!(concurrent.persistent_root.is_none());
        concurrent
            .upsert(2, b"concurrent isolated overlay")
            .unwrap();
        concurrent.flush().unwrap();
        concurrent.persist(b"must not replace owner").unwrap();
        assert_eq!(owner.search("owner"), vec![1]);
        assert_eq!(concurrent.search("isolated"), vec![2]);
        drop(owner);
        let reopened = Engine::persistent(root.path()).unwrap();
        assert_eq!(reopened.manifest, b"owner");
        assert_eq!(reopened.search("owner"), vec![1]);
        assert!(reopened.search("concurrent").is_empty());
    }

    #[test]
    fn malformed_or_partial_checkpoint_rebuilds_without_following_paths() {
        let root = tempfile::tempdir().unwrap();
        let checkpoint;
        {
            let mut engine = Engine::persistent(root.path()).unwrap();
            engine.upsert(1, b"original cache data").unwrap();
            engine.flush().unwrap();
            engine.persist(b"original").unwrap();
            checkpoint = engine.checkpoint.clone().unwrap();
        }
        std::fs::write(checkpoint.join("index.bin"), []).unwrap();
        let mut rebuilt = Engine::persistent(root.path()).unwrap();
        assert!(rebuilt.manifest.is_empty());
        assert!(rebuilt.search("original").is_empty());
        rebuilt.upsert(2, b"healthy replacement").unwrap();
        rebuilt.flush().unwrap();
        rebuilt.persist(b"healthy").unwrap();
        assert!(
            !checkpoint.exists(),
            "successful recovery reclaims corrupt checkpoint"
        );
        drop(rebuilt);
        std::fs::write(root.path().join("active"), "../../unowned").unwrap();
        let rebuilt = Engine::persistent(root.path()).unwrap();
        assert!(rebuilt.manifest.is_empty());
        assert!(rebuilt.checkpoint.is_none());
    }

    #[test]
    fn symlinked_cache_root_and_lock_are_rejected() {
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("target");
        std::fs::create_dir(&target).unwrap();
        let link = root.path().join("linked-cache");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(Engine::persistent(&link).is_err());
        assert_eq!(std::fs::read_dir(&target).unwrap().count(), 0);
        std::os::unix::fs::symlink(root.path().join("unowned"), target.join("lock")).unwrap();
        assert!(Engine::persistent(&target).is_err());
        assert!(!root.path().join("unowned").exists());
        std::fs::remove_file(target.join("lock")).unwrap();
        let untouched = root.path().join("untouched");
        std::fs::write(&untouched, b"checkpoint-unowned").unwrap();
        std::os::unix::fs::symlink(&untouched, target.join("active")).unwrap();
        let engine = Engine::persistent(&target).unwrap();
        assert!(engine.manifest.is_empty());
        assert_eq!(std::fs::read(&untouched).unwrap(), b"checkpoint-unowned");
    }

    #[test]
    #[ignore = "repeatable synthetic benchmark, run with --ignored --nocapture"]
    fn benchmark_warm_phrase_candidates() {
        use std::time::Instant;
        let mut engine = Engine::new().unwrap();
        let corpus: Vec<String> = (0..2_000)
            .map(|id| {
                format!(
                    "{} session marker {id} {}",
                    "ordinary developer conversation ".repeat(250),
                    if id == 1703 {
                        "ANE deployment issue"
                    } else {
                        "general discussion"
                    }
                )
            })
            .collect();
        let started = Instant::now();
        for (id, text) in corpus.iter().enumerate() {
            engine.upsert(id as i64, text.as_bytes()).unwrap();
        }
        engine.flush().unwrap();
        let build = started.elapsed();
        let started = Instant::now();
        for _ in 0..100 {
            assert_eq!(engine.search("ANE deployment"), vec![1703]);
        }
        let indexed = started.elapsed();
        let started = Instant::now();
        for _ in 0..100 {
            assert_eq!(
                corpus
                    .iter()
                    .filter(|text| std::hint::black_box(text).contains("ANE deployment"))
                    .count(),
                1
            );
        }
        let scan = started.elapsed();
        eprintln!(
            "synthetic: documents=2000 bytes={} build_ms={:.1} warm_us={:.1} scan_us={:.1} ratio={:.1}x",
            corpus.iter().map(String::len).sum::<usize>(),
            build.as_secs_f64() * 1000.0,
            indexed.as_secs_f64() * 10000.0,
            scan.as_secs_f64() * 10000.0,
            scan.as_secs_f64() / indexed.as_secs_f64()
        );
    }
}
