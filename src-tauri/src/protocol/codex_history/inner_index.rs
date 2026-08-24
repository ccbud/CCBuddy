// Eviction, the call-id reverse index, and the unique-call fallback lookups.

use super::types::{CachedResponse, HistoryInner, ScopedResponseId};
use serde_json::Value;
use std::collections::HashSet;

impl HistoryInner {
    pub(super) fn prune_to_limits(&mut self, max_responses: usize, max_bytes: usize) {
        while self.response_order.len() > max_responses || self.cached_bytes > max_bytes {
            let Some(response_id) = self.response_order.pop_front() else {
                break;
            };
            self.remove_response(&response_id);
        }
    }

    pub(super) fn remove_response(&mut self, response_id: &ScopedResponseId) -> bool {
        self.remove_response_from_call_index(response_id);
        let Some(response) = self.responses.remove(response_id) else {
            return false;
        };
        self.cached_bytes = self.cached_bytes.saturating_sub(response.serialized_bytes);
        true
    }

    pub(super) fn index_call(
        &mut self,
        scope: &str,
        call_id: &str,
        response_id: &ScopedResponseId,
    ) {
        let response_ids = self
            .call_index
            .entry((scope.to_string(), call_id.to_string()))
            .or_default();
        if !response_ids
            .iter()
            .any(|cached_id| cached_id == response_id)
        {
            response_ids.push_back(response_id.clone());
        }
    }

    pub(super) fn remove_response_from_call_index(&mut self, response_id: &ScopedResponseId) {
        for response_ids in self.call_index.values_mut() {
            response_ids.retain(|cached_id| cached_id != response_id);
        }
        self.call_index
            .retain(|_, response_ids| !response_ids.is_empty());
    }

    pub(super) fn unique_fallback_response(
        &self,
        scope: &str,
        requested_call_ids: &HashSet<String>,
        previous: Option<&CachedResponse>,
    ) -> CachedResponse {
        // A resolved previous_response_id is authoritative. Grafting calls from another cached
        // branch onto it would create history that no provider ever observed.
        if previous.is_some() || requested_call_ids.is_empty() {
            return CachedResponse::default();
        }

        let mut source_response_id: Option<ScopedResponseId> = None;
        for call_id in requested_call_ids {
            let Some(response_id) = self.unique_response_for_call(scope, call_id) else {
                return CachedResponse::default();
            };
            if source_response_id
                .as_ref()
                .is_some_and(|source| source != &response_id)
            {
                return CachedResponse::default();
            }
            source_response_id = Some(response_id);
        }

        source_response_id
            .and_then(|response_id| self.responses.get(&response_id).cloned())
            .unwrap_or_default()
    }

    pub(super) fn unique_response_for_call(
        &self,
        scope: &str,
        call_id: &str,
    ) -> Option<ScopedResponseId> {
        let response_ids = self
            .call_index
            .get(&(scope.to_string(), call_id.to_string()))?;
        let mut found: Option<&ScopedResponseId> = None;
        for response_id in response_ids {
            let Some(response) = self.responses.get(response_id) else {
                continue;
            };
            // An owner-only native response may contain just a delta after an unavailable prefix.
            // Its calls are useful to that provider via previous_response_id, but are never a safe
            // source for session fallback because doing so would manufacture a truncated chain.
            if !response.materializable {
                continue;
            }
            if !response.calls_by_id.contains_key(call_id) {
                continue;
            }
            if found.is_some() {
                return None;
            }
            found = Some(response_id);
        }
        found.cloned()
    }

    pub(super) fn unique_call(&self, scope: &str, call_id: &str) -> Option<&Value> {
        let response_id = self.unique_response_for_call(scope, call_id)?;
        self.responses
            .get(&response_id)
            .and_then(|response| response.calls_by_id.get(call_id))
    }
}
