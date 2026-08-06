// Bounded execution of one helper invocation (hard deadline, capped stdout, drained stderr).
// macOS-only (declared `#[cfg(target_os = "macos")] mod exec;`), moved verbatim from qoder.rs.

use std::io;
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use super::guard::too_large;

/// Poll the child for exit until `deadline`; None = still running when time ran out.
#[cfg(target_os = "macos")]
fn wait_deadline(
    child: &mut std::process::Child,
    deadline: Instant,
) -> io::Result<Option<std::process::ExitStatus>> {
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(Some(status));
        }
        if Instant::now() >= deadline {
            return Ok(None);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Run a prepared helper command with a hard deadline. stdout drains on its own thread (bounded
/// at `stdout_cap`), stderr on another (an 8 KiB diagnostic tail, then discarded so a chatty
/// child can't deadlock on a full pipe), the child is killed at the deadline or on an oversized
/// stream, and exit is polled — a helper that closes stdout but never exits still can't pin the
/// calling thread.
#[cfg(target_os = "macos")]
pub(super) fn run_helper_bounded(
    mut cmd: Command,
    stdout_cap: usize,
    timeout: Duration,
    expected_len: usize,
) -> io::Result<Vec<u8>> {
    use std::sync::mpsc;
    let timed_out = || io::Error::new(io::ErrorKind::TimedOut, "Qoder CLI helper timed out");
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let deadline = Instant::now() + timeout;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "Qoder CLI stdout was not captured"))?;
    let (tx, rx) = mpsc::channel();
    // Pre-allocate for the expected payload, capped — metadata could claim MAX_READ_BYTES and an
    // upfront 256 MiB allocation per read is needless; Vec growth covers honest large files.
    let prealloc = expected_len.min(8 * 1024 * 1024);
    let cap = stdout_cap as u64;
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::with_capacity(prealloc);
        let result = stdout.by_ref().take(cap + 1).read_to_end(&mut bytes);
        let _ = tx.send((result, bytes));
    });
    let (etx, erx) = mpsc::channel();
    let stderr_reader = child.stderr.take().map(|mut pipe| {
        std::thread::spawn(move || {
            let mut tail = Vec::with_capacity(1024);
            let _ = pipe.by_ref().take(8192).read_to_end(&mut tail);
            let _ = io::copy(&mut pipe, &mut io::sink());
            let _ = etx.send(tail);
        })
    });
    let kill = |child: &mut std::process::Child| {
        let _ = child.kill();
        let _ = child.wait();
    };
    let remaining = deadline.saturating_duration_since(Instant::now());
    let (read_result, bytes) = match rx.recv_timeout(remaining) {
        Ok(outcome) => outcome,
        Err(_) => {
            kill(&mut child); // pipe closes → reader threads unblock and exit
            let _ = reader.join();
            return Err(timed_out());
        }
    };
    let _ = reader.join();
    if let Err(error) = read_result {
        kill(&mut child);
        return Err(error);
    }
    if bytes.len() > stdout_cap {
        kill(&mut child);
        return Err(too_large());
    }
    let status = match wait_deadline(&mut child, deadline)? {
        Some(status) => status,
        None => {
            kill(&mut child);
            return Err(timed_out());
        }
    };
    let stderr_tail = stderr_reader
        .and_then(|_| erx.recv_timeout(Duration::from_millis(200)).ok())
        .unwrap_or_default();
    if !status.success() {
        let detail = String::from_utf8_lossy(&stderr_tail);
        let detail = detail.trim();
        return Err(io::Error::new(
            io::ErrorKind::Other,
            if detail.is_empty() {
                format!("Qoder CLI helper exited with status {status}")
            } else {
                format!("Qoder CLI helper exited with status {status}: {detail}")
            },
        ));
    }
    Ok(bytes)
}
