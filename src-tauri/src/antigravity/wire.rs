// The schema-less protobuf wire walker used to recover a step payload's stable fields. Moved
// verbatim from antigravity.rs.

// ---- protobuf wire walker (schema-less) ----

pub(super) enum Wire {
    Varint(u64),
    Bytes(Vec<u8>),
    Fixed,
}

/// One message level → (field number, value) pairs. None when the buffer isn't a valid message.
pub(super) fn wire_fields(buf: &[u8]) -> Option<Vec<(u32, Wire)>> {
    let mut out = vec![];
    let mut i = 0usize;
    fn varint(buf: &[u8], i: &mut usize) -> Option<u64> {
        let mut v: u64 = 0;
        let mut shift = 0u32;
        loop {
            let b = *buf.get(*i)?;
            *i += 1;
            v |= ((b & 0x7f) as u64) << shift;
            if b & 0x80 == 0 {
                return Some(v);
            }
            shift += 7;
            if shift > 63 {
                return None;
            }
        }
    }
    while i < buf.len() {
        let tag = varint(buf, &mut i)?;
        let (field, wt) = ((tag >> 3) as u32, tag & 7);
        if field == 0 {
            return None;
        }
        match wt {
            0 => out.push((field, Wire::Varint(varint(buf, &mut i)?))),
            2 => {
                let len = varint(buf, &mut i)? as usize;
                if i + len > buf.len() {
                    return None;
                }
                out.push((field, Wire::Bytes(buf[i..i + len].to_vec())));
                i += len;
            }
            5 => {
                if i + 4 > buf.len() {
                    return None;
                }
                i += 4;
                out.push((field, Wire::Fixed));
            }
            1 => {
                if i + 8 > buf.len() {
                    return None;
                }
                i += 8;
                out.push((field, Wire::Fixed));
            }
            _ => return None,
        }
    }
    Some(out)
}

pub(super) fn field_bytes<'a>(fields: &'a [(u32, Wire)], no: u32) -> Option<&'a [u8]> {
    fields.iter().find_map(|(f, w)| match w {
        Wire::Bytes(b) if *f == no => Some(b.as_slice()),
        _ => None,
    })
}

pub(super) fn field_msg(fields: &[(u32, Wire)], no: u32) -> Option<Vec<(u32, Wire)>> {
    wire_fields(field_bytes(fields, no)?)
}

pub(super) fn field_str(fields: &[(u32, Wire)], no: u32) -> Option<String> {
    let b = field_bytes(fields, no)?;
    let s = std::str::from_utf8(b).ok()?;
    Some(s.to_string())
}

pub(super) fn field_varint(fields: &[(u32, Wire)], no: u32) -> Option<u64> {
    fields.iter().find_map(|(f, w)| match w {
        Wire::Varint(v) if *f == no => Some(*v),
        _ => None,
    })
}

/// `{#1 seconds, #2 nanos}` timestamp message → RFC3339 (ms precision).
pub(super) fn ts_of(fields: &[(u32, Wire)], no: u32) -> Option<String> {
    let m = field_msg(fields, no)?;
    let secs = field_varint(&m, 1)? as i64;
    let nanos = field_varint(&m, 2).unwrap_or(0) as u32;
    let dt = chrono::DateTime::from_timestamp(secs, nanos)?;
    Some(dt.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
}

pub(super) fn ts_ms_of(fields: &[(u32, Wire)], no: u32) -> Option<f64> {
    let m = field_msg(fields, no)?;
    let secs = field_varint(&m, 1)? as f64;
    let nanos = field_varint(&m, 2).unwrap_or(0) as f64;
    Some(secs * 1000.0 + (nanos / 1_000_000.0).floor())
}
