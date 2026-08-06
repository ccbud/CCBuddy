// Cache record types and the bounded store handle: what a recorded Responses turn keeps, plus the
// reverse indexes `resolve` consults when `previous_response_id` is absent or stale.

use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use tokio::sync::RwLock;

pub(super) const MAX_CACHED_RESPONSES: usize = 512;
// Count-bounding alone is not enough once every entry carries the cumulative transcript: a long
// conversation would otherwise make the cache grow quadratically. This is a logical serialized
// size ceiling (including the duplicated call lookup values), which keeps resident memory in the
// same order of magnitude while still leaving ample room for large model contexts.
pub(super) const MAX_CACHED_HISTORY_BYTES: usize = 32 * 1024 * 1024;

pub(super) type ScopedResponseId = (String, String);
pub(super) type ScopedCallId = (String, String);

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum ResponseOrigin {
    #[default]
    Local,
    Native(String),
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ResponseMetadata {
    pub origin: ResponseOrigin,
    pub materializable: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HistoryResolution {
    pub changed: usize,
    pub had_previous_response_id: bool,
    pub previous_found: bool,
    pub previous_materialized: bool,
    pub previous_origin: Option<ResponseOrigin>,
}

#[derive(Debug, Clone, Default)]
pub(super) struct CachedResponse {
    /// Full model-visible input used to create this response. For an incremental
    /// `previous_response_id` request this already includes every earlier request and response.
    pub(super) request_input: Vec<Value>,
    pub(super) output: Vec<Value>,
    pub(super) calls_by_id: HashMap<String, Value>,
    pub(super) call_order: Vec<String>,
    pub(super) serialized_bytes: usize,
    pub(super) origin: ResponseOrigin,
    pub(super) materializable: bool,
}

#[derive(Debug, Default)]
pub(super) struct HistoryInner {
    pub(super) responses: HashMap<ScopedResponseId, CachedResponse>,
    pub(super) response_order: VecDeque<ScopedResponseId>,
    /// Reverse index used only when `previous_response_id` is absent or stale.
    /// A fallback is safe only when a call id resolves to exactly one response.
    pub(super) call_index: HashMap<ScopedCallId, VecDeque<ScopedResponseId>>,
    pub(super) cached_bytes: usize,
}

#[derive(Debug, Clone, Default)]
pub(super) struct CachedLookup {
    pub(super) previous: Option<CachedResponse>,
    pub(super) fallback: CachedResponse,
}

/// Thread-safe, bounded Responses conversation-history store.
#[derive(Debug, Default)]
pub struct CodexHistoryStore {
    pub(super) inner: RwLock<HistoryInner>,
}

impl CachedLookup {
    pub(super) fn call(&self, call_id: &str) -> Option<&Value> {
        self.previous
            .as_ref()
            .and_then(|previous| previous.calls_by_id.get(call_id))
            .or_else(|| self.fallback.calls_by_id.get(call_id))
    }
}
