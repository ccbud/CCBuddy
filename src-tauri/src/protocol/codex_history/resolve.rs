// Resolving a Responses request against the cache: restoring the previous turn's context, then
// enriching or materializing the request input.

use super::cache_items::{
    enrich_call_item_from_cache, is_call_item_type, is_call_output_item_type,
    response_item_call_id,
};
use super::merge::merge_previous_context;
use super::types::{CachedLookup, CachedResponse, CodexHistoryStore, HistoryResolution};
use serde_json::Value;
use std::collections::HashSet;

impl CodexHistoryStore {
    pub(super) async fn resolve_request_scoped(
        &self,
        scope: &str,
        allow_call_id_fallback: bool,
        strip_materialized_previous_id: bool,
        body: &mut Value,
    ) -> HistoryResolution {
        let previous_response_id = body
            .get("previous_response_id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string);
        let had_previous_response_id = previous_response_id.is_some();

        let input_was_missing = body.get("input").is_none();
        let original_input = body.get_mut("input").map(std::mem::take);
        let original_was_object = original_input.as_ref().is_some_and(Value::is_object);
        let mut original_string = None;
        let mut unsupported_input = None;
        let items = match original_input {
            Some(Value::Array(items)) => items,
            Some(Value::Object(object)) => vec![Value::Object(object)],
            Some(Value::String(value)) => {
                original_string = Some(value.clone());
                vec![serde_json::json!({
                    "type": "message",
                    "role": "user",
                    "content": value,
                })]
            }
            Some(other) => {
                unsupported_input = Some(other);
                Vec::new()
            }
            None => Vec::new(),
        };

        let output_call_ids = items
            .iter()
            .filter(|item| {
                item.get("type")
                    .and_then(Value::as_str)
                    .is_some_and(is_call_output_item_type)
            })
            .filter_map(response_item_call_id)
            .collect::<HashSet<_>>();
        let existing_call_ids = items
            .iter()
            .filter(|item| {
                item.get("type")
                    .and_then(Value::as_str)
                    .is_some_and(is_call_item_type)
            })
            .filter_map(response_item_call_id)
            .collect::<HashSet<_>>();
        let requested_call_ids = output_call_ids
            .union(&existing_call_ids)
            .cloned()
            .collect::<HashSet<_>>();

        let lookup = self
            .lookup(
                scope,
                previous_response_id.as_deref(),
                &requested_call_ids,
                allow_call_id_fallback,
            )
            .await;
        let previous_found = lookup.previous.is_some();
        let previous_origin = lookup
            .previous
            .as_ref()
            .map(|response| response.origin.clone());
        let previous_materialized = lookup
            .previous
            .as_ref()
            .is_some_and(|response| response.materializable);

        if let Some(original_input) = unsupported_input {
            if let Some(object) = body.as_object_mut() {
                object.insert("input".to_string(), original_input);
            }
            return HistoryResolution {
                changed: 0,
                had_previous_response_id,
                previous_found,
                previous_materialized: false,
                previous_origin,
            };
        }

        // A native provider may still own a continuation that the gateway observed only after a
        // restart. Keep that request byte-for-byte intact for same-provider passthrough; callers
        // must reject it before cross-wire/provider-switch forwarding because its prefix is absent.
        if previous_found && !previous_materialized {
            if !input_was_missing {
                let restored_input = if original_string.is_some() && items.len() == 1 {
                    Value::String(original_string.unwrap_or_default())
                } else if original_was_object && items.len() == 1 {
                    items.into_iter().next().unwrap_or(Value::Null)
                } else {
                    Value::Array(items)
                };
                if let Some(object) = body.as_object_mut() {
                    object.insert("input".to_string(), restored_input);
                }
            }
            return HistoryResolution {
                changed: 0,
                had_previous_response_id,
                previous_found,
                previous_materialized,
                previous_origin,
            };
        }
        let replay_context = lookup
            .previous
            .as_ref()
            .or_else(|| lookup.fallback.materializable.then_some(&lookup.fallback));
        let (items, restored) = merge_previous_context(items, replay_context);
        let mut enriched = 0usize;
        let mut new_items = Vec::with_capacity(items.len());

        for mut item in items {
            if item
                .get("type")
                .and_then(Value::as_str)
                .is_some_and(is_call_item_type)
            {
                if let Some(call_id) = response_item_call_id(&item) {
                    if let Some(cached) = lookup.call(&call_id) {
                        if enrich_call_item_from_cache(&mut item, cached) {
                            enriched += 1;
                        }
                    }
                }
            }
            new_items.push(item);
        }

        let changed = restored + enriched;
        let resolved_input = if changed == 0 && original_string.is_some() && new_items.len() == 1 {
            Some(Value::String(original_string.unwrap_or_default()))
        } else if changed == 0 && original_was_object && new_items.len() == 1 {
            Some(new_items.into_iter().next().unwrap_or(Value::Null))
        } else if input_was_missing && changed == 0 {
            None
        } else {
            Some(Value::Array(new_items))
        };
        if let (Some(object), Some(resolved_input)) = (body.as_object_mut(), resolved_input) {
            object.insert("input".to_string(), resolved_input);
        }
        if strip_materialized_previous_id && previous_materialized {
            if let Some(object) = body.as_object_mut() {
                object.remove("previous_response_id");
            }
        }
        HistoryResolution {
            changed,
            had_previous_response_id,
            previous_found,
            previous_materialized,
            previous_origin,
        }
    }

    pub(super) async fn lookup(
        &self,
        scope: &str,
        previous_response_id: Option<&str>,
        requested_call_ids: &HashSet<String>,
        allow_call_id_fallback: bool,
    ) -> CachedLookup {
        let inner = self.inner.read().await;
        let previous = previous_response_id.and_then(|id| {
            inner
                .responses
                .get(&(scope.to_string(), id.to_string()))
                .cloned()
        });
        let fallback = if allow_call_id_fallback {
            inner.unique_fallback_response(scope, requested_call_ids, previous.as_ref())
        } else {
            CachedResponse::default()
        };
        CachedLookup { previous, fallback }
    }
}
