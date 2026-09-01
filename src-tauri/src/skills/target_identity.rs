#[cfg(unix)]
pub fn stable(metadata: &std::fs::Metadata) -> Vec<u8> {
    use std::os::unix::fs::MetadataExt;
    format!(
        "{}:{}:{}:{}:{}:{}:{}",
        metadata.dev(),
        metadata.ino(),
        metadata.mode(),
        metadata.nlink(),
        metadata.uid(),
        metadata.gid(),
        metadata.size()
    )
    .into_bytes()
}

#[cfg(windows)]
pub fn stable(metadata: &std::fs::Metadata) -> Vec<u8> {
    use std::os::windows::fs::MetadataExt;
    format!(
        "{:?}:{:?}:{}:{}:{}",
        metadata.volume_serial_number(),
        metadata.file_index(),
        metadata.file_attributes(),
        metadata.creation_time(),
        metadata.file_size()
    )
    .into_bytes()
}

#[cfg(not(any(unix, windows)))]
pub fn stable(metadata: &std::fs::Metadata) -> Vec<u8> {
    format!("{:?}:{}", metadata.file_type(), metadata.len()).into_bytes()
}

#[cfg(unix)]
pub fn version(metadata: &std::fs::Metadata) -> Vec<u8> {
    use std::os::unix::fs::MetadataExt;
    format!(
        "{}:{}:{}:{}:{}",
        metadata.size(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ctime(),
        metadata.ctime_nsec()
    )
    .into_bytes()
}

#[cfg(windows)]
pub fn version(metadata: &std::fs::Metadata) -> Vec<u8> {
    use std::os::windows::fs::MetadataExt;
    format!(
        "{}:{}:{:?}",
        metadata.file_size(),
        metadata.last_write_time(),
        metadata.change_time()
    )
    .into_bytes()
}

#[cfg(not(any(unix, windows)))]
pub fn version(metadata: &std::fs::Metadata) -> Vec<u8> {
    let modified = metadata
        .modified()
        .ok()
        .and_then(|value| value.duration_since(std::time::UNIX_EPOCH).ok());
    format!("{}:{modified:?}", metadata.len()).into_bytes()
}
