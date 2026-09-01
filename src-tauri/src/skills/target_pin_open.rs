use std::fs::File;
use std::path::Path;

#[cfg(target_os = "linux")]
pub fn open_entry(path: &Path) -> std::io::Result<File> {
    ensure_supported(path)?;
    open_with_flags(path, libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC)
}

#[cfg(all(unix, not(target_os = "linux")))]
pub fn open_entry(path: &Path) -> std::io::Result<File> {
    let metadata = std::fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() {
        return open_symlink(path);
    }
    if !metadata.is_file() && !metadata.is_dir() {
        return Err(unsupported_type());
    }
    open_with_flags(
        path,
        libc::O_RDONLY | libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC,
    )
}

#[cfg(target_os = "macos")]
fn open_symlink(path: &Path) -> std::io::Result<File> {
    open_with_flags(path, libc::O_SYMLINK | libc::O_CLOEXEC)
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn open_symlink(_path: &Path) -> std::io::Result<File> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "pinning symlinks is unsupported on this platform",
    ))
}

#[cfg(unix)]
fn open_with_flags(path: &Path, flags: libc::c_int) -> std::io::Result<File> {
    use std::os::fd::FromRawFd;
    use std::os::unix::ffi::OsStrExt;
    let path = std::ffi::CString::new(path.as_os_str().as_bytes())?;
    let descriptor = unsafe { libc::open(path.as_ptr(), flags) };
    if descriptor < 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(unsafe { File::from_raw_fd(descriptor) })
    }
}

#[cfg(windows)]
pub fn open_entry(path: &Path) -> std::io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;

    ensure_supported(path)?;
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(0x0020_0000 | 0x0200_0000)
        .open(path)
}

#[cfg(not(any(unix, windows)))]
pub fn open_entry(path: &Path) -> std::io::Result<File> {
    ensure_supported(path)?;
    File::open(path)
}

#[cfg(any(target_os = "linux", windows, not(any(unix, windows))))]
fn ensure_supported(path: &Path) -> std::io::Result<()> {
    let metadata = std::fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || metadata.is_file() || metadata.is_dir() {
        Ok(())
    } else {
        Err(unsupported_type())
    }
}

fn unsupported_type() -> std::io::Error {
    std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "unsupported target filesystem type",
    )
}

pub fn handle_matches(handle: &File, path: &Path) -> Result<bool, String> {
    let held = match handle.metadata() {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound || is_stale(&error) => {
            return Ok(false);
        }
        Err(error) => return Err(format!("inspect pinned target: {error}")),
    };
    if !is_linked(&held) {
        return Ok(false);
    }
    let current = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(format!("inspect pinned path {}: {error}", path.display())),
    };
    Ok(super::target_identity::stable(&held) == super::target_identity::stable(&current))
}

#[cfg(unix)]
fn is_stale(error: &std::io::Error) -> bool {
    error.raw_os_error() == Some(libc::ESTALE)
}

#[cfg(not(unix))]
fn is_stale(_error: &std::io::Error) -> bool {
    false
}

#[cfg(unix)]
fn is_linked(metadata: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    metadata.nlink() != 0
}

#[cfg(not(unix))]
fn is_linked(_metadata: &std::fs::Metadata) -> bool {
    true
}
