// Inserting a recorded response into the bounded cache, with the byte/count accounting that keeps
// a long conversation from growing the cache quadratically.

use super::cache_items::cached_call_item;
use super::sizing::cached_response_size;
use super::types::{
    CachedResponse, HistoryInner, ResponseOrigin, MAX_CACHED_HISTORY_BYTES, MAX_CACHED_RESPONSES,
};
use serde_json::Value;

impl HistoryInner {
    pub(super) fn insert_response(
        &mut self,
        scope: &str,
        response_id: &str,
        request_input: Vec<Value>,
        output: Vec<Value>,
    ) -> usize {
        self.insert_response_with_metadata(
            scope,
            response_id,
            request_input,
            output,
            ResponseOrigin::Local,
            true,
        )
    }

    pub(super) fn insert_response_with_metadata(
        &mut self,
        scope: &str,
        response_id: &str,
        request_input: Vec<Value>,
        output: Vec<Value>,
        origin: ResponseOrigin,
        materializable: bool,
    ) -> usize {
        self.insert_response_with_metadata_and_limits(
            scope,
            response_id,
            request_input,
            output,
            origin,
            materializable,
            MAX_CACHED_RESPONSES,
            MAX_CACHED_HISTORY_BYTES,
        )
    }

    pub(super) fn insert_response_with_limits(
        &mut self,
        scope: &str,
        response_id: &str,
        request_input: Vec<Value>,
        output: Vec<Value>,
        max_responses: usize,
        max_bytes: usize,
    ) -> usize {
        self.insert_response_with_metadata_and_limits(
            scope,
            response_id,
            request_input,
            output,
            ResponseOrigin::Local,
            true,
            max_responses,
            max_bytes,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn insert_response_with_metadata_and_limits(
        &mut self,
        scope: &str,
        response_id: &str,
        request_input: Vec<Value>,
        output: Vec<Value>,
        origin: ResponseOrigin,
        materializable: bool,
        max_responses: usize,
        max_bytes: usize,
    ) -> usize {
        let mut cached_response = CachedResponse {
            request_input,
            output,
            origin,
            materializable,
            ..CachedResponse::default()
        };
        for item in &cached_response.output {
            if let Some((call_id, item)) = cached_call_item(item) {
                if !cached_response.calls_by_id.contains_key(&call_id) {
                    cached_response.call_order.push(call_id.clone());
                }
                cached_response.calls_by_id.insert(call_id, item);
            }
        }
        cached_response.serialized_bytes =
            cached_response_size(scope, response_id, &cached_response);
        let cached_count = cached_response.output.len();
        let response_key = (scope.to_string(), response_id.to_string());

        // Never let one pathological request flush every useful older entry before being evicted
        // itself. A same-id response is authoritative, though, so an oversized replacement drops
        // only its stale predecessor rather than leaving old history addressable under that id.
        if cached_response.serialized_bytes > max_bytes {
            if self.remove_response(&response_key) {
                self.response_order
                    .retain(|cached_id| cached_id != &response_key);
            }
            return 0;
        }

        let replacing = self.responses.contains_key(&response_key);
        if !replacing {
            self.response_order.push_back(response_key.clone());
        }

        // A completed response is authoritative. Replacing an already-seen id keeps
        // retry/replay recording idempotent and prevents stale call-index entries.
        self.remove_response(&response_key);

        for call_id in &cached_response.call_order {
            self.index_call(scope, &call_id, &response_key);
        }
        self.cached_bytes = self
            .cached_bytes
            .checked_add(cached_response.serialized_bytes)
            .unwrap_or(usize::MAX);
        self.responses.insert(response_key.clone(), cached_response);
        self.prune_to_limits(max_responses, max_bytes);
        if self.responses.contains_key(&response_key) {
            cached_count
        } else {
            0
        }
    }
}
