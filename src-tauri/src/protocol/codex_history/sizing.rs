// Serialized-size accounting for the cache's byte budget.

use super::types::{CachedResponse, ResponseOrigin};
use std::io::{self, Write};

#[derive(Default)]
struct ByteCounter {
    bytes: usize,
}

impl Write for ByteCounter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.bytes = self.bytes.saturating_add(buf.len());
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub(super) fn serialized_size<T: serde::Serialize + ?Sized>(value: &T) -> usize {
    let mut counter = ByteCounter::default();
    if serde_json::to_writer(&mut counter, value).is_err() {
        usize::MAX
    } else {
        counter.bytes
    }
}

pub(super) fn cached_response_size(
    scope: &str,
    response_id: &str,
    response: &CachedResponse,
) -> usize {
    let origin_bytes = match &response.origin {
        ResponseOrigin::Local => 1,
        ResponseOrigin::Native(provider_id) => 1usize.saturating_add(serialized_size(provider_id)),
    };
    serialized_size(scope)
        .saturating_add(serialized_size(response_id))
        .saturating_add(serialized_size(&response.request_input))
        .saturating_add(serialized_size(&response.output))
        .saturating_add(serialized_size(&response.calls_by_id))
        .saturating_add(serialized_size(&response.call_order))
        .saturating_add(origin_bytes)
        .saturating_add(1)
}
