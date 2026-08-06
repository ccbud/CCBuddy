// Recording a translated Responses turn and the public request-enrichment entry points.

use super::cache_items::cached_output_item;
use super::materialize::{
    history_item_is_materializable, request_input_is_materializable, request_input_items,
};
use super::types::{CodexHistoryStore, HistoryResolution, ResponseMetadata, ResponseOrigin};
use serde_json::Value;

impl CodexHistoryStore {
    /// Record the full translated request input plus supported assistant-output items from a
    /// resumable terminal Responses response (`completed` or `incomplete`).
    ///
    /// Returns the number of cached output items. Responses without an id are ignored; an otherwise
    /// empty response is still retained so provider ownership remains known.
    pub async fn record_response(&self, request: &Value, response: &Value) -> usize {
        self.record_response_scoped("", request, response).await
    }

    /// Scoped variant used by the gateway so response/call ids from different client sessions can
    /// never satisfy one another while the same conversation can survive a provider switch.
    pub async fn record_response_scoped(
        &self,
        scope: &str,
        request: &Value,
        response: &Value,
    ) -> usize {
        // Preserve the original store API for internal callers/tests that predate Responses
        // terminal statuses. Gateway-owned/native recording uses the metadata variant below,
        // which requires an explicit resumable terminal status.
        let mut legacy_terminal;
        let response = if response.get("status").is_none() {
            legacy_terminal = response.clone();
            legacy_terminal["status"] = Value::String("completed".to_string());
            &legacy_terminal
        } else {
            response
        };
        self.record_response_scoped_with_metadata(
            scope,
            ResponseOrigin::Local,
            true,
            request,
            response,
        )
        .await
    }

    pub async fn record_response_scoped_with_metadata(
        &self,
        scope: &str,
        origin: ResponseOrigin,
        materializable: bool,
        request: &Value,
        response: &Value,
    ) -> usize {
        if response
            .get("object")
            .and_then(Value::as_str)
            .is_some_and(|object| object != "response")
        {
            return 0;
        }
        if !matches!(
            response.get("status").and_then(Value::as_str),
            Some("completed" | "incomplete")
        ) {
            return 0;
        }

        let Some(response_id) = response
            .get("id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
            return 0;
        };

        let request_input = request_input_items(request);
        let request_input_is_complete = request_input_is_materializable(request);
        let (output, output_is_complete) = match response.get("output").and_then(Value::as_array) {
            Some(items) => {
                let output = items
                    .iter()
                    .filter_map(cached_output_item)
                    .collect::<Vec<_>>();
                let output_is_complete =
                    output.len() == items.len() && items.iter().all(history_item_is_materializable);
                (output, output_is_complete)
            }
            None => (Vec::new(), false),
        };
        // Preserve ownership for a response containing an item this bridge cannot replay, but
        // never advertise that partial transcript as safe to move to another provider.
        let materializable = materializable && request_input_is_complete && output_is_complete;

        self.inner.write().await.insert_response_with_metadata(
            scope,
            response_id,
            request_input,
            output,
            origin,
            materializable,
        )
    }

    pub async fn response_metadata(
        &self,
        scope: &str,
        response_id: &str,
    ) -> Option<ResponseMetadata> {
        let response_id = response_id.trim();
        if response_id.is_empty() {
            return None;
        }
        self.inner
            .read()
            .await
            .responses
            .get(&(scope.to_string(), response_id.to_string()))
            .map(|response| ResponseMetadata {
                origin: response.origin.clone(),
                materializable: response.materializable,
            })
    }

    /// Restore or enrich call items required by a follow-up Responses request.
    ///
    /// Missing calls are inserted immediately before the first matching output.
    /// Parallel calls from the same response are restored as one ordered group.
    /// Existing call items are enriched when fields such as `name`, `arguments`,
    /// or `reasoning_content` are missing.
    ///
    /// The primary lookup uses `previous_response_id`. If that id is absent or
    /// stale, a call-id fallback is used only when the caller supplied a safe scope and the call id
    /// is unique inside that client session. Returns the number of restored or enriched items.
    pub async fn enrich_request(&self, body: &mut Value) -> usize {
        self.enrich_request_scoped("", false, body).await
    }

    /// Scoped variant. Missing/stale-`previous_response_id` call-id recovery is allowed only when
    /// the caller can provide a client-session scope; otherwise orphan validation must fail.
    pub async fn enrich_request_scoped(
        &self,
        scope: &str,
        allow_call_id_fallback: bool,
        body: &mut Value,
    ) -> usize {
        self.resolve_request_scoped(scope, allow_call_id_fallback, false, body)
            .await
            .changed
    }

    pub async fn materialize_request_scoped(
        &self,
        scope: &str,
        allow_call_id_fallback: bool,
        body: &mut Value,
    ) -> HistoryResolution {
        self.resolve_request_scoped(scope, allow_call_id_fallback, true, body)
            .await
    }
}
