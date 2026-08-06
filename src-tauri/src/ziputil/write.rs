// Writing: CRC-32, raw DEFLATE, and the local-header + central-directory layout.
// STORE or DEFLATE per entry (whichever is smaller), no zip64, no data descriptors.

use flate2::write::DeflateEncoder;
use flate2::Compression;
use std::io::Write;

pub struct Entry {
    pub name: String,
    pub data: Vec<u8>,
}

pub(super) fn crc32(data: &[u8]) -> u32 {
    let mut crc: u32 = 0xffff_ffff;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    !crc
}

fn deflate(data: &[u8]) -> Option<Vec<u8>> {
    let mut enc = DeflateEncoder::new(Vec::new(), Compression::default());
    enc.write_all(data).ok()?;
    enc.finish().ok()
}

/// Build a .zip from entries. STORE unless raw-DEFLATE is strictly smaller.
pub fn build(entries: &[Entry]) -> Vec<u8> {
    let mut local: Vec<u8> = Vec::new();
    let mut central: Vec<u8> = Vec::new();
    let mut offset: u32 = 0;
    for e in entries {
        let name = e.name.as_bytes();
        let crc = crc32(&e.data);
        let deflated = deflate(&e.data);
        let (method, payload): (u16, &[u8]) = match &deflated {
            Some(d) if d.len() < e.data.len() => (8, d.as_slice()),
            _ => (0, e.data.as_slice()),
        };
        let comp_size = payload.len() as u32;
        let uncomp_size = e.data.len() as u32;

        // local file header
        local.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        local.extend_from_slice(&20u16.to_le_bytes()); // version needed
        local.extend_from_slice(&0u16.to_le_bytes()); // flags
        local.extend_from_slice(&method.to_le_bytes());
        local.extend_from_slice(&0u16.to_le_bytes()); // mod time
        local.extend_from_slice(&0x21u16.to_le_bytes()); // mod date = 1980-01-01
        local.extend_from_slice(&crc.to_le_bytes());
        local.extend_from_slice(&comp_size.to_le_bytes());
        local.extend_from_slice(&uncomp_size.to_le_bytes());
        local.extend_from_slice(&(name.len() as u16).to_le_bytes());
        local.extend_from_slice(&0u16.to_le_bytes()); // extra length
        local.extend_from_slice(name);
        local.extend_from_slice(payload);

        // central directory header
        central.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes()); // version made by
        central.extend_from_slice(&20u16.to_le_bytes()); // version needed
        central.extend_from_slice(&0u16.to_le_bytes()); // flags
        central.extend_from_slice(&method.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes()); // mod time
        central.extend_from_slice(&0x21u16.to_le_bytes()); // mod date
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&comp_size.to_le_bytes());
        central.extend_from_slice(&uncomp_size.to_le_bytes());
        central.extend_from_slice(&(name.len() as u16).to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes()); // extra length
        central.extend_from_slice(&0u16.to_le_bytes()); // comment length
        central.extend_from_slice(&0u16.to_le_bytes()); // disk number start
        central.extend_from_slice(&0u16.to_le_bytes()); // internal attrs
        central.extend_from_slice(&0u32.to_le_bytes()); // external attrs
        central.extend_from_slice(&offset.to_le_bytes()); // relative offset of local header
        central.extend_from_slice(name);

        offset += 30 + name.len() as u32 + comp_size;
    }
    let central_start = offset;
    let central_size = central.len() as u32;
    let mut out = local;
    out.extend_from_slice(&central);
    // end of central directory record
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // this disk
    out.extend_from_slice(&0u16.to_le_bytes()); // disk with central dir
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes()); // entries this disk
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes()); // total entries
    out.extend_from_slice(&central_size.to_le_bytes());
    out.extend_from_slice(&central_start.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // comment length
    out
}
