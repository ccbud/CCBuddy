//! A narrow in-process ABI around upstream tgrep. No shell, server, telemetry,
//! producer-file traversal, or original transcript copies are involved.
//!
//! The caller supplies canonical, case-folded UTF-8 documents and stable catalog
//! IDs. Only trigrams and numeric IDs reach the private temporary disk index.
//! The live overlay is flushed every 64 MiB of input; streaming merges keep the
//! full corpus's postings in mmap instead of a second in-memory transcript store.

use std::cell::Cell;
use std::collections::HashSet;
use std::ffi::{CStr, CString, OsStr, OsString, c_void};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::MetadataExt;
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

/// The Swift boundary already supplies Foundation-folded, NFC bytes. The bridge
/// needs only presence, not upstream's per-position or next-byte masks. Keep the
/// upstream collision-free trigram keys and purpose-built hasher, but avoid
/// computing and merging two masks for every input byte.
fn extract_normalized_trigrams(text: &[u8]) -> Vec<u32> {
    let mut trigrams: HashSet<u32, tgrep_core::trigram::BuildTrigramHasher> =
        HashSet::with_capacity_and_hasher(text.len().min(16_384), Default::default());
    for bytes in text.windows(3) {
        trigrams.insert(tgrep_core::trigram::hash(bytes[0], bytes[1], bytes[2]));
    }
    trigrams.into_iter().collect()
}
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

const WORKING_PREFIX: &str = "ccbuddy-tgrep-";
const WORKING_LEASE: &str = ".ccbuddy-working-lease-v1";
const WORKING_REGISTRY: &str = ".ccbuddy-working-registry-v1";

fn unsafe_cache_io() -> std::io::Error {
    std::io::Error::other(UnsafeCache)
}

fn same_file(left: &std::fs::Metadata, right: &std::fs::Metadata) -> bool {
    left.dev() == right.dev() && left.ino() == right.ino()
}

fn component_name(name: &OsStr) -> std::io::Result<CString> {
    let bytes = name.as_bytes();
    if bytes.is_empty() || bytes == b"." || bytes == b".." || bytes.contains(&b'/') {
        return Err(unsafe_cache_io());
    }
    CString::new(bytes).map_err(|_| unsafe_cache_io())
}

fn open_at(parent: &std::fs::File, name: &OsStr, flags: i32) -> std::io::Result<std::fs::File> {
    let name = component_name(name)?;
    // All traversal is relative to an already-open directory. Never follow a final
    // symlink; NONBLOCK also prevents a replaced lease FIFO from hanging startup.
    let descriptor = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            0o600,
        )
    };
    if descriptor < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { std::fs::File::from_raw_fd(descriptor) })
}

fn open_directory(path: &Path) -> std::io::Result<std::fs::File> {
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
}

fn open_directory_at(parent: &std::fs::File, name: &OsStr) -> std::io::Result<std::fs::File> {
    open_at(parent, name, libc::O_RDONLY | libc::O_DIRECTORY)
}

fn private_regular_file(file: &std::fs::File) -> std::io::Result<bool> {
    let metadata = file.metadata()?;
    Ok(metadata.is_file()
        && metadata.uid() == unsafe { libc::geteuid() }
        && metadata.nlink() == 1
        && metadata.permissions().mode() & 0o777 == 0o600)
}

fn open_private_lock(parent: &std::fs::File, name: &str) -> std::io::Result<std::fs::File> {
    // Separate lookup from exclusive creation. Concurrent O_CREAT|O_NOFOLLOW
    // opens can transiently report ENOENT on macOS while another thread creates
    // the entry. O_EXCL gives us a definite winner and a safe reopen for peers.
    for _ in 0..16 {
        let file = match open_at(parent, OsStr::new(name), libc::O_RDWR) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                match open_at(
                    parent,
                    OsStr::new(name),
                    libc::O_RDWR | libc::O_CREAT | libc::O_EXCL,
                ) {
                    Ok(file) => file,
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                    Err(error) => return Err(error),
                }
            }
            Err(error) => return Err(error),
        };
        if !private_regular_file(&file)? {
            return Err(unsafe_cache_io());
        }
        return Ok(file);
    }
    Err(unsafe_cache_io())
}

fn exclusive_lock(file: &std::fs::File, nonblocking: bool) -> std::io::Result<bool> {
    loop {
        let flags = libc::LOCK_EX | if nonblocking { libc::LOCK_NB } else { 0 };
        if unsafe { libc::flock(file.as_raw_fd(), flags) } == 0 {
            return Ok(true);
        }
        let error = std::io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(libc::EWOULDBLOCK) if nonblocking => return Ok(false),
            _ => return Err(error),
        }
    }
}

struct PublisherLease(std::fs::File);

impl Drop for PublisherLease {
    fn drop(&mut self) {
        // A concurrent posix_spawn can briefly inherit the file description before
        // CLOEXEC closes it in the child. Merely closing the parent's fd can then
        // leave a finished publisher spuriously "alive" for a same-process reopen.
        // This wrapper drops last in Engine, after its workspace is gone; explicitly
        // relinquish this owner's lock rather than relying on the last fd closing.
        let _ = unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}

fn working_lease_contents(
    parent: &std::fs::File,
    directory: &std::fs::File,
) -> std::io::Result<Vec<u8>> {
    let root = parent.metadata()?;
    let working = directory.metadata()?;
    Ok(format!(
        "ccbuddy-working-lease-v1\n{}:{}\n{}:{}\n",
        root.dev(),
        root.ino(),
        working.dev(),
        working.ino()
    )
    .into_bytes())
}

fn directory_names(directory: &std::fs::File) -> std::io::Result<Vec<OsString>> {
    // openat(".") obtains a fresh directory cursor. dup() would share the offset
    // and could make a second validation/deletion pass silently miss entries.
    let descriptor = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            c".".as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
        )
    };
    if descriptor < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let file = unsafe { std::fs::File::from_raw_fd(descriptor) };
    let stream = unsafe { libc::fdopendir(file.as_raw_fd()) };
    if stream.is_null() {
        return Err(std::io::Error::last_os_error());
    }
    let _ = file.into_raw_fd(); // fdopendir owns it after success.
    struct DirectoryStream(*mut libc::DIR);
    impl Drop for DirectoryStream {
        fn drop(&mut self) {
            unsafe {
                libc::closedir(self.0);
            }
        }
    }
    let stream = DirectoryStream(stream);
    let mut names = Vec::new();
    loop {
        // readdir_r is deprecated; errno distinguishes an error from end-of-directory.
        #[cfg(target_os = "macos")]
        unsafe {
            *libc::__error() = 0;
        }
        #[cfg(target_os = "linux")]
        unsafe {
            *libc::__errno_location() = 0;
        }
        let entry = unsafe { libc::readdir(stream.0) };
        if entry.is_null() {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(0) {
                return Err(error);
            }
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if name != b"." && name != b".." {
            names.push(OsString::from_vec(name.to_vec()));
        }
    }
    Ok(names)
}

fn entry_stat(parent: &std::fs::File, name: &OsStr) -> std::io::Result<libc::stat> {
    let name = component_name(name)?;
    let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            metadata.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { metadata.assume_init() })
}

fn entry_matches(
    parent: &std::fs::File,
    name: &OsStr,
    file: &std::fs::File,
) -> std::io::Result<bool> {
    let entry = entry_stat(parent, name)?;
    let opened = file.metadata()?;
    Ok(entry.st_dev as u64 == opened.dev() && entry.st_ino == opened.ino())
}

fn unlink_at(parent: &std::fs::File, name: &OsStr, directory: bool) -> std::io::Result<()> {
    let name = component_name(name)?;
    if unsafe {
        libc::unlinkat(
            parent.as_raw_fd(),
            name.as_ptr(),
            if directory { libc::AT_REMOVEDIR } else { 0 },
        )
    } != 0
    {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

fn walk_working_tree(
    directory: &std::fs::File,
    device: u64,
    remove: bool,
    depth: usize,
) -> std::io::Result<()> {
    if depth > 32 {
        return Err(unsafe_cache_io());
    }
    for name in directory_names(directory)? {
        let metadata = entry_stat(directory, &name)?;
        if metadata.st_uid != unsafe { libc::geteuid() } || metadata.st_dev as u64 != device {
            return Err(unsafe_cache_io());
        }
        match metadata.st_mode & libc::S_IFMT {
            libc::S_IFDIR => {
                let child = open_directory_at(directory, &name)?;
                if !entry_matches(directory, &name, &child)? {
                    return Err(unsafe_cache_io());
                }
                walk_working_tree(&child, device, remove, depth + 1)?;
                if remove {
                    if !entry_matches(directory, &name, &child)? {
                        return Err(unsafe_cache_io());
                    }
                    unlink_at(directory, &name, true)?;
                }
            }
            libc::S_IFREG => {
                // Unlinking a workspace's immutable postings hard link preserves its
                // published checkpoint (and never writes through to the shared inode).
                // Keep the lease until all bulky data is gone. A reaper killed halfway
                // through deletion must leave a recognizable, resumable workspace.
                if remove && !(depth == 0 && name == WORKING_LEASE) {
                    unlink_at(directory, &name, false)?;
                }
            }
            _ => return Err(unsafe_cache_io()), // Symlinks, sockets, FIFOs and devices are not ours.
        }
    }
    Ok(())
}

fn valid_working_lease(
    parent: &std::fs::File,
    name: &OsStr,
    directory: &std::fs::File,
    lease: &std::fs::File,
) -> std::io::Result<bool> {
    let metadata = directory.metadata()?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o777 != 0o700
        || !entry_matches(parent, name, directory)?
        || !private_regular_file(lease)?
        || !entry_matches(directory, OsStr::new(WORKING_LEASE), lease)?
    {
        return Ok(false);
    }
    let expected = working_lease_contents(parent, directory)?;
    if lease.metadata()?.len() != expected.len() as u64 {
        return Ok(false);
    }
    use std::os::unix::fs::FileExt;
    let mut actual = vec![0; expected.len()];
    lease.read_exact_at(&mut actual, 0)?;
    Ok(actual == expected)
}

fn remove_leased_working_directory(
    parent: &std::fs::File,
    name: &OsStr,
    directory: &std::fs::File,
    lease: &std::fs::File,
) -> std::io::Result<()> {
    if !valid_working_lease(parent, name, directory, lease)? {
        return Err(unsafe_cache_io());
    }
    let device = directory.metadata()?.dev();
    // Preflight the whole tree before deleting anything. A malformed or symlinked
    // legacy/foreign layout stays untouched; the deletion pass checks again.
    walk_working_tree(directory, device, false, 0)?;
    if !valid_working_lease(parent, name, directory, lease)? {
        return Err(unsafe_cache_io());
    }
    walk_working_tree(directory, device, true, 0)?;
    if !entry_matches(parent, name, directory)? {
        return Err(unsafe_cache_io());
    }
    if !valid_working_lease(parent, name, directory, lease)? {
        return Err(unsafe_cache_io());
    }
    unlink_at(directory, OsStr::new(WORKING_LEASE), false)?;
    unlink_at(parent, name, true)
}

fn reclaim_abandoned_working_directories(parent: &std::fs::File) -> std::io::Result<()> {
    for name in directory_names(parent)? {
        let Some(name_string) = name.to_str() else {
            continue;
        };
        let Some(suffix) = name_string.strip_prefix(WORKING_PREFIX) else {
            continue;
        };
        if suffix.is_empty() || !suffix.bytes().all(|byte| byte.is_ascii_alphanumeric()) {
            continue;
        }
        // Missing/invalid leases include old versions' workspaces: no age or PID
        // heuristic can prove those inactive, so leave them alone.
        let Ok(directory) = open_directory_at(parent, &name) else {
            continue;
        };
        let Ok(lease) = open_at(&directory, OsStr::new(WORKING_LEASE), libc::O_RDWR) else {
            continue;
        };
        if !valid_working_lease(parent, &name, &directory, &lease).unwrap_or(false)
            || !exclusive_lock(&lease, true).unwrap_or(false)
        {
            continue;
        }
        let _ = remove_leased_working_directory(parent, &name, &directory, &lease);
        // The kernel releases the lease only after cleanup, including error paths.
    }
    Ok(())
}

struct WorkingDirectory {
    path: PathBuf,
    parent: std::fs::File,
    name: OsString,
    directory: std::fs::File,
    lease: std::fs::File,
}

impl WorkingDirectory {
    fn new(parent: Option<&Path>) -> std::io::Result<Self> {
        let parent_path = parent
            .map(Path::to_owned)
            .unwrap_or_else(std::env::temp_dir)
            .canonicalize()?;
        let parent = open_directory(&parent_path)?;
        let temporary = tempfile::Builder::new()
            .prefix(WORKING_PREFIX)
            .tempdir_in(&parent_path)?;
        let name = temporary.path().file_name().unwrap().to_owned();
        let directory = open_directory_at(&parent, &name)?;
        if !same_file(
            &directory.metadata()?,
            &std::fs::symlink_metadata(temporary.path())?,
        ) {
            return Err(unsafe_cache_io());
        }
        directory.set_permissions(std::fs::Permissions::from_mode(0o700))?;
        let mut lease = open_at(
            &directory,
            OsStr::new(WORKING_LEASE),
            libc::O_RDWR | libc::O_CREAT | libc::O_EXCL,
        )?;
        exclusive_lock(&lease, false)?;
        lease.write_all(&working_lease_contents(&parent, &directory)?)?;
        lease.sync_all()?;
        directory.sync_all()?;
        Ok(Self {
            path: temporary.keep(),
            parent,
            name,
            directory,
            lease,
        })
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for WorkingDirectory {
    fn drop(&mut self) {
        // Keep the exclusive file description alive until after removal. Startup
        // reapers therefore cannot race a still-live Engine, even in this process.
        let _ =
            remove_leased_working_directory(&self.parent, &self.name, &self.directory, &self.lease);
    }
}

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
    directory: WorkingDirectory,
    pending_bytes: usize,
    sequence: u64,
    active_directory: Option<std::path::PathBuf>,
    persistent_root: Option<PathBuf>,
    checkpoint: Option<PathBuf>,
    manifest: Vec<u8>,
    _lease: Option<PublisherLease>,
}

impl Engine {
    fn new() -> Result<Self, Box<dyn std::error::Error>> {
        Self::new_in(None)
    }

    fn new_in(parent: Option<&Path>) -> Result<Self, Box<dyn std::error::Error>> {
        // Harden before any postings are written; no history paths or query
        // text are used in its name. It is removed when the database closes.
        let directory = WorkingDirectory::new(parent)?;
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
        match std::fs::symlink_metadata(root) {
            Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
            Ok(_) => return Err(UnsafeCache.into()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                std::fs::create_dir_all(root)?
            }
            Err(error) => return Err(error.into()),
        }
        let root_handle = open_directory(root)?;
        if root_handle.metadata()?.uid() != unsafe { libc::geteuid() } {
            return Err(UnsafeCache.into());
        }
        root_handle.set_permissions(std::fs::Permissions::from_mode(0o700))?;
        let root_path = root.canonicalize()?;
        if !same_file(
            &root_handle.metadata()?,
            &std::fs::symlink_metadata(&root_path)?,
        ) {
            return Err(UnsafeCache.into());
        }
        let root = root_path.as_path();
        let lease = open_private_lock(&root_handle, "lock")?;
        let owns_lease = exclusive_lock(&lease, true)?;
        let mut engine = {
            // Independent of the lifetime publisher lease: every publisher and
            // secondary coordinates workspace creation with opportunistic reaping.
            let registry = open_private_lock(&root_handle, WORKING_REGISTRY)?;
            exclusive_lock(&registry, false)?;
            reclaim_abandoned_working_directories(&root_handle)?;
            Self::new_in(Some(root))?
        };
        if !owns_lease {
            // Another database instance can use an isolated overlay on the same
            // volume without racing publication of the persistent checkpoint.
            return Ok(engine);
        }
        engine._lease = Some(PublisherLease(lease));
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
                    if let Ok(index) = HybridIndex::open(&checkpoint, root)
                        && let Ok(metadata) =
                            std::fs::metadata(checkpoint.join("ccbuddy-manifest.json"))
                        && metadata.len() <= 16 * 1024 * 1024
                    {
                        engine.manifest = std::fs::read(checkpoint.join("ccbuddy-manifest.json"))
                            .unwrap_or_default();
                        engine.index = index;
                        engine.active_directory = None;
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
        let trigrams = extract_normalized_trigrams(text);
        self.index
            .live
            .upsert_file_with_trigrams(&id.to_string(), trigrams);
        self.pending_bytes = self.pending_bytes.saturating_add(text.len());
        if self.pending_bytes >= FLUSH_BYTES {
            self.flush()?;
        }
        Ok(())
    }

    /// A sealed reader can continue using its immutable mmaps while a separate
    /// background engine acquires the sole publisher lease and builds its next
    /// checkpoint. Never remove the reader's live workspace or current files.
    fn relinquish_publisher(&mut self) {
        self.persistent_root = None;
        self._lease = None;
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

/// # Safety
/// `bytes` must reference `length` readable bytes for the duration of this call.
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

/// # Safety
/// `engine` must be a live handle, with no concurrent mutation or destruction.
/// Non-null `output` must reference `capacity` writable bytes, disjoint from the handle.
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

/// # Safety
/// `engine` must be an exclusively accessed live handle. `bytes` must reference
/// `length` readable bytes and must not alias the handle's mutable storage.
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

/// Additive ABI-v2 operation: retain a sealed reader while handing publication
/// authority to the next background builder. Repeated calls are harmless.
///
/// # Safety
/// `engine` must be an exclusively accessed live handle, with no pending writes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ccbuddy_tgrep_relinquish_publisher(engine: *mut c_void) -> i32 {
    if engine.is_null() {
        LAST_ERROR_CODE.set(4);
        return -1;
    }
    ffi_result(-1, || {
        let engine = unsafe { &mut *engine.cast::<Engine>() };
        if engine.index.live.has_pending_changes() {
            return Err(std::io::Error::other("unsealed publication handoff").into());
        }
        engine.relinquish_publisher();
        Ok(0)
    })
}

/// # Safety
/// A non-null handle must have been returned by this library and must be destroyed
/// exactly once, after all access to it has stopped.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ccbuddy_tgrep_destroy(engine: *mut c_void) {
    if !engine.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(engine.cast::<Engine>()));
        }));
    }
}

/// # Safety
/// `engine` must be an exclusively accessed live handle. `bytes` must reference
/// `length` readable bytes and must not alias the handle's mutable storage.
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

/// # Safety
/// `engine` must be an exclusively accessed live handle. When `count` is nonzero,
/// `ids` must reference that many aligned, readable i64 values disjoint from the handle.
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
///
/// # Safety
/// `engine` must be a live handle without concurrent mutation or destruction.
/// `bytes` must reference `length` readable bytes; non-null `output` must reference
/// `capacity` aligned, writable i64 values disjoint from the handle and input.
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
    fn normalized_presence_extraction_matches_independent_byte_window_oracle() {
        let mut inputs = vec![
            Vec::new(),
            vec![0],
            vec![0, 1],
            vec![0, 1, 2],
            "系统代理\0strasse café 👩‍💻".as_bytes().to_vec(),
            vec![b'a'; 262_144],
        ];
        let mut random = Vec::with_capacity(262_144);
        let mut seed = 0x74ab_9871u32;
        for _ in 0..262_144 {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            random.push(seed as u8);
        }
        inputs.push(random);
        for input in inputs {
            let expected: std::collections::BTreeSet<u32> = input
                .windows(3)
                .map(|bytes| u32::from_be_bytes([0, bytes[0], bytes[1], bytes[2]]))
                .collect();
            let actual = extract_normalized_trigrams(&input);
            assert_eq!(actual.len(), expected.len());
            assert_eq!(
                actual
                    .into_iter()
                    .collect::<std::collections::BTreeSet<_>>(),
                expected
            );
        }
    }

    #[test]
    fn publisher_handoff_preserves_old_reader_and_allows_successor_checkpoint() {
        let root = tempfile::tempdir().unwrap();
        let mut reader = Engine::persistent(root.path()).unwrap();
        reader.upsert(1, b"first sealed needle").unwrap();
        reader.flush().unwrap();
        reader.persist(b"first manifest").unwrap();
        reader.relinquish_publisher();
        reader.relinquish_publisher();
        let mut successor = Engine::persistent(root.path()).unwrap();
        assert!(successor.persistent_root.is_some());
        assert_eq!(successor.manifest, b"first manifest");
        let competing = Engine::persistent(root.path()).unwrap();
        assert!(competing.persistent_root.is_none());
        successor.upsert(1, b"second sealed replacement").unwrap();
        successor.flush().unwrap();
        successor.persist(b"second manifest").unwrap();
        assert_eq!(reader.search("needle"), vec![1]);
        assert!(reader.search("replacement").is_empty());
        assert_eq!(successor.search("replacement"), vec![1]);
        drop(competing);
        drop(reader);
        assert_eq!(successor.search("replacement"), vec![1]);
        drop(successor);
        let reopened = Engine::persistent(root.path()).unwrap();
        assert_eq!(reopened.manifest, b"second manifest");
        assert_eq!(reopened.search("replacement"), vec![1]);
    }

    #[test]
    fn abandoned_successor_keeps_checkpoint_and_handoff_can_retry() {
        let root = tempfile::tempdir().unwrap();
        let mut reader = Engine::persistent(root.path()).unwrap();
        reader.upsert(1, b"last complete original").unwrap();
        reader.flush().unwrap();
        reader.persist(b"durable original").unwrap();
        reader.relinquish_publisher();
        {
            let mut canceled = Engine::persistent(root.path()).unwrap();
            assert!(canceled.persistent_root.is_some());
            canceled.upsert(2, b"uncommitted replacement").unwrap();
        }
        assert_eq!(reader.search("original"), vec![1]);
        let mut retry = Engine::persistent(root.path()).unwrap();
        assert!(retry.persistent_root.is_some());
        assert_eq!(retry.manifest, b"durable original");
        assert!(retry.search("replacement").is_empty());
        retry.upsert(2, b"published retry").unwrap();
        retry.flush().unwrap();
        retry.persist(b"retry complete").unwrap();
        assert_eq!(reader.search("original"), vec![1]);
        assert_eq!(retry.search("retry"), vec![2]);
    }

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
        assert!(
            reopened.persistent_root.is_some(),
            "first checkpoint reopen unexpectedly found another live publisher lease"
        );
        assert_eq!(reopened.manifest, b"manifest-one");
        assert_eq!(reopened.search("committed"), vec![1]);
        assert!(reopened.search("unpublished").is_empty());
        reopened.upsert(1, b"published replacement").unwrap();
        reopened.flush().unwrap();
        reopened.persist(b"manifest-two").unwrap();
        drop(reopened);
        let latest = Engine::persistent(root.path()).unwrap();
        assert!(
            latest.persistent_root.is_some(),
            "checkpoint reopen unexpectedly found another live publisher lease"
        );
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

    fn working_paths(root: &Path) -> Vec<PathBuf> {
        std::fs::read_dir(root)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| {
                path.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with(WORKING_PREFIX)
            })
            .collect()
    }

    /// A completed v1 lease with no remaining owner. This models the on-disk
    /// state after exit without relying on a PID, wall clock, or leaked test fd.
    fn abandoned_working_directory(root: &Path) -> PathBuf {
        abandoned_working_directory_observing_lease(root, |_| {})
    }

    fn abandoned_working_directory_observing_lease(
        root: &Path,
        observe_lease: impl FnOnce(&std::fs::File),
    ) -> PathBuf {
        let temporary = tempfile::Builder::new()
            .prefix(WORKING_PREFIX)
            .tempdir_in(root)
            .unwrap();
        let parent = open_directory(root).unwrap();
        let directory = open_directory(temporary.path()).unwrap();
        directory
            .set_permissions(std::fs::Permissions::from_mode(0o700))
            .unwrap();
        let mut lease = open_at(
            &directory,
            OsStr::new(WORKING_LEASE),
            libc::O_RDWR | libc::O_CREAT | libc::O_EXCL,
        )
        .unwrap();
        exclusive_lock(&lease, false).unwrap();
        lease
            .write_all(&working_lease_contents(&parent, &directory).unwrap())
            .unwrap();
        std::fs::create_dir(temporary.path().join("index-1")).unwrap();
        std::fs::write(
            temporary.path().join("index-1/index.bin"),
            b"discardable postings",
        )
        .unwrap();
        observe_lease(&lease);
        // Parallel process fixtures can inherit this open file description before
        // CLOEXEC runs. Closing only our fd would leave the "abandoned" fixture
        // spuriously locked; explicitly finish its owner before publishing it.
        assert_eq!(unsafe { libc::flock(lease.as_raw_fd(), libc::LOCK_UN) }, 0);
        temporary.keep()
    }

    #[test]
    fn normal_exit_removes_working_hardlinks_without_changing_checkpoint() {
        let root = tempfile::tempdir().unwrap();
        let mut engine = Engine::persistent(root.path()).unwrap();
        engine
            .upsert(19, b"immutable checkpoint survives working unlink")
            .unwrap();
        engine.flush().unwrap();
        engine.persist(b"sealed manifest").unwrap();
        let working = engine.directory.path().to_owned();
        let source = engine.active_directory.as_ref().unwrap().join("index.bin");
        let sealed = engine.checkpoint.as_ref().unwrap().join("index.bin");
        assert!(same_file(
            &std::fs::metadata(&source).unwrap(),
            &std::fs::metadata(&sealed).unwrap()
        ));
        assert_eq!(std::fs::metadata(&sealed).unwrap().nlink(), 2);
        let checksum = checkpoint_checksums(engine.checkpoint.as_ref().unwrap()).unwrap();
        drop(engine);
        assert!(!working.exists());
        assert_eq!(std::fs::metadata(&sealed).unwrap().nlink(), 1);
        assert_eq!(
            checkpoint_checksums(sealed.parent().unwrap()).unwrap(),
            checksum
        );
        let reopened = Engine::persistent(root.path()).unwrap();
        assert_eq!(reopened.manifest, b"sealed manifest");
        assert_eq!(reopened.search("immutable checkpoint"), vec![19]);
        drop(reopened);
        assert!(working_paths(root.path()).is_empty());
    }

    #[test]
    fn completed_publisher_releases_lease_even_with_a_spawn_inherited_descriptor() {
        let root = tempfile::tempdir().unwrap();
        let mut publisher = Engine::persistent(root.path()).unwrap();
        publisher.upsert(1, b"publisher exited normally").unwrap();
        publisher.flush().unwrap();
        publisher.persist(b"published before spawn").unwrap();
        // dup models the same open file description inherited during posix_spawn.
        // It is not another Engine and must not keep a completed publisher alive.
        let inherited = publisher._lease.as_ref().unwrap().0.try_clone().unwrap();
        drop(publisher);
        let replacement = Engine::persistent(root.path()).unwrap();
        assert!(replacement.persistent_root.is_some());
        assert_eq!(replacement.manifest, b"published before spawn");
        assert_eq!(replacement.search("publisher exited"), vec![1]);
        drop(inherited);
    }

    #[test]
    fn repeated_startups_reclaim_only_proven_abandoned_workspaces() {
        let root = tempfile::tempdir().unwrap();
        let stale: Vec<_> = (0..5)
            .map(|_| abandoned_working_directory(root.path()))
            .collect();
        let legacy = root.path().join("ccbuddy-tgrep-legacy");
        std::fs::create_dir(&legacy).unwrap();
        std::fs::write(legacy.join("unowned"), b"preserve legacy").unwrap();
        for _ in 0..4 {
            let engine = Engine::persistent(root.path()).unwrap();
            assert!(stale.iter().all(|path| !path.exists()));
            assert_eq!(
                working_paths(root.path()).len(),
                2,
                "one live workspace plus untouched legacy"
            );
            drop(engine);
            assert_eq!(working_paths(root.path()), vec![legacy.clone()]);
        }
        assert_eq!(
            std::fs::read(legacy.join("unowned")).unwrap(),
            b"preserve legacy"
        );
    }

    #[test]
    fn reaper_preserves_invalid_identity_permissions_hardlinks_and_symlinks() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let sentinel = outside.path().join("sentinel");
        std::fs::write(&sentinel, b"outside data stays untouched").unwrap();
        let malformed = abandoned_working_directory(root.path());
        std::fs::write(malformed.join(WORKING_LEASE), b"not a recognized lease").unwrap();
        let permissive = abandoned_working_directory(root.path());
        std::fs::set_permissions(
            permissive.join(WORKING_LEASE),
            std::fs::Permissions::from_mode(0o644),
        )
        .unwrap();
        let linked_lease = abandoned_working_directory(root.path());
        std::fs::hard_link(
            linked_lease.join(WORKING_LEASE),
            outside.path().join("lease-alias"),
        )
        .unwrap();
        let nested_symlink = abandoned_working_directory(root.path());
        symlink(
            outside.path(),
            nested_symlink.join("index-1/foreign-directory"),
        )
        .unwrap();
        let symlinked_lease = abandoned_working_directory(root.path());
        std::fs::remove_file(symlinked_lease.join(WORKING_LEASE)).unwrap();
        symlink(&sentinel, symlinked_lease.join(WORKING_LEASE)).unwrap();
        let moved = abandoned_working_directory(outside.path());
        let moved_here = root.path().join(moved.file_name().unwrap());
        std::fs::rename(&moved, &moved_here).unwrap();
        let symlinked_directory = root.path().join("ccbuddy-tgrep-linked");
        symlink(outside.path(), &symlinked_directory).unwrap();
        let engine = Engine::persistent(root.path()).unwrap();
        for path in [
            &malformed,
            &permissive,
            &linked_lease,
            &nested_symlink,
            &symlinked_lease,
            &moved_here,
        ] {
            assert_eq!(
                std::fs::read(path.join("index-1/index.bin")).unwrap(),
                b"discardable postings",
                "unsafe layouts must not even be partially deleted"
            );
        }
        assert!(
            std::fs::symlink_metadata(&symlinked_directory)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(
            std::fs::read(&sentinel).unwrap(),
            b"outside data stays untouched"
        );
        drop(engine);
    }

    #[test]
    fn anchored_cleanup_refuses_replaced_directory_and_out_of_bounds_names() {
        let root = tempfile::tempdir().unwrap();
        let engine = Engine::persistent(root.path()).unwrap();
        let original_path = engine.directory.path().to_owned();
        let moved = root.path().join("renamed-owned-workspace");
        std::fs::rename(&original_path, &moved).unwrap();
        std::fs::create_dir(&original_path).unwrap();
        std::fs::write(original_path.join("foreign"), b"replacement directory").unwrap();
        for name in ["..", ".", "../outside", "/outside", "a/b"] {
            assert!(open_directory_at(&engine.directory.parent, OsStr::new(name)).is_err());
            assert!(unlink_at(&engine.directory.parent, OsStr::new(name), true).is_err());
        }
        drop(engine);
        assert_eq!(
            std::fs::read(original_path.join("foreign")).unwrap(),
            b"replacement directory"
        );
        assert!(
            moved.join(WORKING_LEASE).exists(),
            "a replacement path must not cause deletion of another directory"
        );
    }

    #[test]
    fn interrupted_cleanup_keeps_lease_until_bulky_files_are_removed() {
        let root = tempfile::tempdir().unwrap();
        let stale = abandoned_working_directory(root.path());
        let directory = open_directory(&stale).unwrap();
        walk_working_tree(&directory, directory.metadata().unwrap().dev(), true, 0).unwrap();
        assert_eq!(
            directory_names(&directory).unwrap(),
            vec![OsString::from(WORKING_LEASE)]
        );
        // The next process recognizes and finishes the interrupted cleanup.
        let engine = Engine::persistent(root.path()).unwrap();
        assert!(!stale.exists());
        drop(engine);
    }

    #[test]
    fn abandoned_fixture_is_reapable_with_a_spawn_inherited_descriptor() {
        let root = tempfile::tempdir().unwrap();
        let mut inherited = None;
        let stale = abandoned_working_directory_observing_lease(root.path(), |lease| {
            // Model the shared open file description inherited before CLOEXEC.
            inherited = Some(lease.try_clone().unwrap());
        });
        let engine = Engine::persistent(root.path()).unwrap();
        assert!(
            !stale.exists(),
            "a fixture marked abandoned must not retain a live lock through an inherited fd"
        );
        drop(engine);
        drop(inherited);
    }

    #[test]
    fn registry_lock_rejects_symlinks_and_hardlink_aliases() {
        let root = tempfile::tempdir().unwrap();
        let sentinel = root.path().join("foreign-lock");
        std::fs::write(&sentinel, b"foreign lock contents").unwrap();
        std::fs::set_permissions(&sentinel, std::fs::Permissions::from_mode(0o600)).unwrap();
        let registry = root.path().join(WORKING_REGISTRY);
        std::os::unix::fs::symlink(&sentinel, &registry).unwrap();
        assert!(Engine::persistent(root.path()).is_err());
        std::fs::remove_file(&registry).unwrap();
        std::fs::hard_link(&sentinel, &registry).unwrap();
        assert!(Engine::persistent(root.path()).is_err());
        std::fs::remove_file(&registry).unwrap();
        let fifo = CString::new(registry.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        assert!(
            Engine::persistent(root.path()).is_err(),
            "a replaced lock FIFO must be rejected without blocking"
        );
        assert_eq!(std::fs::read(&sentinel).unwrap(), b"foreign lock contents");
        assert!(working_paths(root.path()).is_empty());
    }

    #[test]
    fn concurrent_creators_and_reapers_never_remove_a_live_workspace() {
        use std::sync::{Arc, Barrier};
        let root = tempfile::tempdir().unwrap();
        let start = Arc::new(Barrier::new(9));
        let workers: Vec<_> = (0..8)
            .map(|worker| {
                let root = root.path().to_owned();
                let start = start.clone();
                std::thread::spawn(move || {
                    start.wait();
                    for iteration in 0..6 {
                        let mut engine = Engine::persistent(&root).unwrap();
                        let text = format!("unique-worker-{worker}-iteration-{iteration}-marker");
                        engine.upsert(worker, text.as_bytes()).unwrap();
                        engine.flush().unwrap();
                        engine.persist(b"concurrent checkpoint").unwrap();
                        assert!(engine.directory.path().exists());
                        assert_eq!(engine.search(&text), vec![worker]);
                    }
                })
            })
            .collect();
        start.wait();
        for worker in workers {
            worker.join().unwrap();
        }
        assert!(working_paths(root.path()).is_empty());
    }

    struct WorkspaceProcess {
        child: std::process::Child,
        lines: std::sync::mpsc::Receiver<String>,
        reader: Option<std::thread::JoinHandle<()>>,
        workspace: PathBuf,
        is_publisher: bool,
    }

    impl WorkspaceProcess {
        fn start(root: &Path) -> Self {
            use std::io::BufRead;
            let mut child = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "tests::workspace_process_fixture",
                    "--nocapture",
                    "--test-threads=1",
                ])
                .env("CCBUD_TGREP_TEST_WORKSPACE_ROOT", root)
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::inherit())
                .spawn()
                .unwrap();
            let output = child.stdout.take().unwrap();
            let (send, lines) = std::sync::mpsc::channel();
            let reader = std::thread::spawn(move || {
                for line in std::io::BufReader::new(output).lines() {
                    let Ok(line) = line else {
                        break;
                    };
                    if send.send(line).is_err() {
                        break;
                    }
                }
            });
            let mut process = Self {
                child,
                lines,
                reader: Some(reader),
                workspace: PathBuf::new(),
                is_publisher: false,
            };
            let ready = process.wait_for("LEASE_READY:");
            let (name, owner) = ready
                .strip_prefix("LEASE_READY:")
                .unwrap()
                .split_once(':')
                .unwrap();
            assert!(name.starts_with(WORKING_PREFIX));
            component_name(OsStr::new(name)).unwrap();
            process.workspace = root.join(name);
            process.is_publisher = owner == "true";
            process
        }

        fn wait_for(&self, prefix: &str) -> String {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
            loop {
                let remaining = deadline.saturating_duration_since(std::time::Instant::now());
                let line = self.lines.recv_timeout(remaining).expect(
                    "child fixture must reach explicit readiness within its bounded startup budget",
                );
                // libtest may prefix the first stdout line with the test name.
                if let Some(offset) = line.find(prefix) {
                    return line[offset..].to_owned();
                }
            }
        }

        fn verify_alive(&mut self) {
            self.child.stdin.as_mut().unwrap().write_all(b"V").unwrap();
            assert_eq!(self.wait_for("LEASE_ALIVE"), "LEASE_ALIVE");
        }

        fn prepare_unpublished_change(&mut self) {
            self.child.stdin.as_mut().unwrap().write_all(b"U").unwrap();
            assert_eq!(self.wait_for("LEASE_UNPUBLISHED"), "LEASE_UNPUBLISHED");
        }

        fn kill(&mut self) {
            use std::os::unix::process::ExitStatusExt;
            self.child.kill().unwrap();
            assert_eq!(self.child.wait().unwrap().signal(), Some(libc::SIGKILL));
        }

        fn finish(&mut self) {
            self.child.stdin.as_mut().unwrap().write_all(b"Q").unwrap();
            assert_eq!(self.wait_for("LEASE_DROPPED"), "LEASE_DROPPED");
            assert!(self.child.wait().unwrap().success());
        }
    }

    impl Drop for WorkspaceProcess {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
            if let Some(reader) = self.reader.take() {
                let _ = reader.join();
            }
        }
    }

    #[test]
    fn workspace_process_fixture() {
        let Some(root) = std::env::var_os("CCBUD_TGREP_TEST_WORKSPACE_ROOT") else {
            return;
        };
        let mut engine = Engine::persistent(Path::new(&root)).unwrap();
        engine.upsert(73, b"live child fixture postings").unwrap();
        engine.flush().unwrap();
        engine.persist(b"child checkpoint").unwrap();
        println!(
            "LEASE_READY:{}:{}",
            engine.directory.name.to_str().unwrap(),
            engine.persistent_root.is_some()
        );
        std::io::stdout().flush().unwrap();
        let mut command = [0];
        while std::io::stdin().read_exact(&mut command).is_ok() {
            if command[0] == b'Q' {
                break;
            }
            if command[0] == b'U' {
                engine.upsert(73, b"unpublished child replacement").unwrap();
                engine.flush().unwrap();
                println!("LEASE_UNPUBLISHED");
                std::io::stdout().flush().unwrap();
                continue;
            }
            assert_eq!(command[0], b'V');
            assert!(engine.directory.path().exists());
            assert_eq!(engine.search("live child fixture"), vec![73]);
            println!("LEASE_ALIVE");
            std::io::stdout().flush().unwrap();
        }
        let path = engine.directory.path().to_owned();
        drop(engine);
        assert!(!path.exists());
        println!("LEASE_DROPPED");
        std::io::stdout().flush().unwrap();
    }

    #[test]
    fn killed_publisher_is_reclaimed_and_its_hardlinked_checkpoint_recovers() {
        let root = tempfile::tempdir().unwrap();
        let mut child = WorkspaceProcess::start(root.path());
        assert!(child.is_publisher);
        let secondary = Engine::persistent(root.path()).unwrap();
        assert!(secondary.persistent_root.is_none());
        child.verify_alive();
        drop(secondary);
        child.verify_alive();
        child.prepare_unpublished_change();
        child.kill();
        assert!(
            child.workspace.exists(),
            "SIGKILL must leave a genuine abandoned workspace"
        );
        let recovered = Engine::persistent(root.path()).unwrap();
        assert!(!child.workspace.exists());
        assert_eq!(recovered.manifest, b"child checkpoint");
        assert_eq!(recovered.search("live child fixture"), vec![73]);
        assert!(recovered.search("unpublished child replacement").is_empty());
        drop(recovered);
        assert!(working_paths(root.path()).is_empty());
    }

    #[test]
    fn publisher_replacement_preserves_live_secondary_in_another_process() {
        let root = tempfile::tempdir().unwrap();
        let mut publisher = Engine::persistent(root.path()).unwrap();
        publisher.upsert(1, b"parent publisher checkpoint").unwrap();
        publisher.flush().unwrap();
        publisher.persist(b"parent checkpoint").unwrap();
        let mut child = WorkspaceProcess::start(root.path());
        assert!(!child.is_publisher);
        child.verify_alive();
        drop(publisher);
        let replacement = Engine::persistent(root.path()).unwrap();
        assert!(replacement.persistent_root.is_some());
        assert_eq!(replacement.manifest, b"parent checkpoint");
        assert_eq!(replacement.search("parent publisher"), vec![1]);
        child.verify_alive();
        child.finish();
        assert!(!child.workspace.exists());
        drop(replacement);
        assert!(working_paths(root.path()).is_empty());
    }

    #[test]
    fn relinquished_reader_survives_cross_process_publisher_and_competing_secondary() {
        let root = tempfile::tempdir().unwrap();
        let mut reader = Engine::persistent(root.path()).unwrap();
        reader.upsert(1, b"stable prehandoff needle").unwrap();
        reader.flush().unwrap();
        reader.persist(b"prehandoff manifest").unwrap();
        reader.relinquish_publisher();
        let mut publisher = WorkspaceProcess::start(root.path());
        assert!(publisher.is_publisher);
        assert_eq!(reader.search("prehandoff needle"), vec![1]);
        let mut competing = Engine::persistent(root.path()).unwrap();
        assert!(competing.persistent_root.is_none());
        competing.upsert(99, b"private competing overlay").unwrap();
        competing.flush().unwrap();
        competing
            .persist(b"cannot replace cross process publisher")
            .unwrap();
        publisher.verify_alive();
        assert_eq!(reader.search("prehandoff needle"), vec![1]);
        drop(competing);
        drop(reader);
        publisher.verify_alive();
        publisher.finish();
        let recovered = Engine::persistent(root.path()).unwrap();
        assert!(recovered.persistent_root.is_some());
        assert_eq!(recovered.manifest, b"child checkpoint");
        assert_eq!(recovered.search("prehandoff needle"), vec![1]);
        assert_eq!(recovered.search("live child fixture"), vec![73]);
        assert!(recovered.search("competing overlay").is_empty());
    }

    #[test]
    fn secondary_reaper_cleans_killed_peer_without_touching_active_instances() {
        let root = tempfile::tempdir().unwrap();
        let mut publisher = Engine::persistent(root.path()).unwrap();
        publisher.upsert(1, b"active publisher contents").unwrap();
        publisher.flush().unwrap();
        publisher.persist(b"active manifest").unwrap();
        let mut active_secondary = Engine::persistent(root.path()).unwrap();
        active_secondary
            .upsert(2, b"active secondary contents")
            .unwrap();
        active_secondary.flush().unwrap();
        let mut child = WorkspaceProcess::start(root.path());
        assert!(!child.is_publisher);
        child.kill();
        assert!(child.workspace.exists());
        let reaper = Engine::persistent(root.path()).unwrap();
        assert!(reaper.persistent_root.is_none());
        assert!(!child.workspace.exists());
        assert!(publisher.directory.path().exists());
        assert!(active_secondary.directory.path().exists());
        assert_eq!(publisher.search("active publisher"), vec![1]);
        assert_eq!(active_secondary.search("active secondary"), vec![2]);
        drop(reaper);
        drop(active_secondary);
        drop(publisher);
        assert!(working_paths(root.path()).is_empty());
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
