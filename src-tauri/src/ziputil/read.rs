// Reading: parse via the central directory (so OS-repacked zips with data descriptors still
// read), handling STORE (0) and DEFLATE (8). Unreadable members are skipped, never panic.

use super::write::Entry;
use flate2::read::DeflateDecoder;
use std::io::Read;

fn rd_u16(buf: &[u8], at: usize) -> Option<u16> {
    buf.get(at..at + 2).map(|s| u16::from_le_bytes([s[0], s[1]]))
}
fn rd_u32(buf: &[u8], at: usize) -> Option<u32> {
    buf.get(at..at + 4).map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}

/// Parse a .zip → entries. Best-effort: unreadable/unsupported members are skipped.
pub fn read(buf: &[u8]) -> Vec<Entry> {
    let mut out: Vec<Entry> = Vec::new();
    if buf.len() < 22 {
        return out;
    }
    // Locate the End Of Central Directory record by scanning backwards for its signature.
    let mut eocd: Option<usize> = None;
    let top = buf.len() - 22;
    let floor = top.saturating_sub(65535);
    let mut i = top;
    loop {
        if rd_u32(buf, i) == Some(0x0605_4b50) {
            eocd = Some(i);
            break;
        }
        if i <= floor {
            break;
        }
        i -= 1;
    }
    let eocd = match eocd {
        Some(e) => e,
        None => return out,
    };
    let count = rd_u16(buf, eocd + 10).unwrap_or(0) as usize;
    let mut p = rd_u32(buf, eocd + 16).unwrap_or(0) as usize; // central directory offset
    for _ in 0..count {
        if rd_u32(buf, p) != Some(0x0201_4b50) {
            break;
        }
        let method = rd_u16(buf, p + 10).unwrap_or(0);
        let comp_size = rd_u32(buf, p + 20).unwrap_or(0) as usize;
        let name_len = rd_u16(buf, p + 28).unwrap_or(0) as usize;
        let extra_len = rd_u16(buf, p + 30).unwrap_or(0) as usize;
        let comment_len = rd_u16(buf, p + 32).unwrap_or(0) as usize;
        let local_off = rd_u32(buf, p + 42).unwrap_or(0) as usize;
        let name = buf
            .get(p + 46..(p + 46 + name_len).min(buf.len()))
            .map(|s| String::from_utf8_lossy(s).into_owned())
            .unwrap_or_default();
        // The local header repeats name/extra lengths; trust it for the data offset.
        if rd_u32(buf, local_off) == Some(0x0403_4b50) {
            let lh_name = rd_u16(buf, local_off + 26).unwrap_or(0) as usize;
            let lh_extra = rd_u16(buf, local_off + 28).unwrap_or(0) as usize;
            let data_start = local_off + 30 + lh_name + lh_extra;
            let data_end = data_start + comp_size;
            if data_end <= buf.len() {
                let payload = &buf[data_start..data_end];
                let data = match method {
                    0 => Some(payload.to_vec()),
                    8 => {
                        let mut v = Vec::new();
                        DeflateDecoder::new(payload).read_to_end(&mut v).ok().map(|_| v)
                    }
                    _ => None,
                };
                if let Some(data) = data {
                    out.push(Entry { name, data });
                }
            }
        }
        p += 46 + name_len + extra_len + comment_len;
    }
    out
}
