// Merging a referenced response's model-visible context into a continuation request's input.

use super::materialize::cached_item_matches_input;
use super::types::CachedResponse;
use serde_json::Value;
use std::collections::HashMap;

/// Merge the directly referenced response's complete model-visible context into the new input.
///
/// The cached request prefix is always restored before the previous response output. A client that
/// already sent the full prefix is detected by a matching request prefix plus at least one prior
/// output anchor, while a coincidentally repeated new user message is still treated as a delta.
/// Every supported previous output item is restored. Filtering unmatched calls would no longer be
/// equivalent to provider-side `previous_response_id` continuation and could silently turn an
/// invalid continuation into a different, truncated conversation.
pub(super) fn merge_previous_context(
    items: Vec<Value>,
    previous: Option<&CachedResponse>,
) -> (Vec<Value>, usize) {
    let Some(previous) = previous else {
        return (items, 0);
    };

    let eligible_output = previous.output.clone();
    let request_prefix_len = previous.request_input.len();
    let has_request_prefix = request_prefix_len <= items.len()
        && previous
            .request_input
            .iter()
            .zip(&items)
            .all(|(cached, input)| cached_item_matches_input(cached, input));
    let has_output_anchor = has_request_prefix
        && !previous.output.is_empty()
        && previous.output.iter().any(|cached| {
            items[request_prefix_len..]
                .iter()
                .any(|input| cached_item_matches_input(cached, input))
        });

    let (prefix, tail, restored_input) = if has_request_prefix && has_output_anchor {
        (
            items[..request_prefix_len].to_vec(),
            items[request_prefix_len..].to_vec(),
            0,
        )
    } else {
        (
            previous.request_input.clone(),
            items,
            previous.request_input.len(),
        )
    };
    let (tail, restored_output) = merge_cached_output(tail, &eligible_output);
    let mut merged = Vec::with_capacity(prefix.len() + tail.len());
    merged.extend(prefix);
    merged.extend(tail);
    (merged, restored_input + restored_output)
}

pub(super) fn merge_cached_output(items: Vec<Value>, eligible: &[Value]) -> (Vec<Value>, usize) {
    if eligible.is_empty() {
        return (items, 0);
    }

    // Match explicit prior-output items monotonically. Legal explicit history keeps
    // response order, and monotonic matching avoids treating a coincidentally reused
    // text value later in the request as the prior item.
    let mut matches = HashMap::<usize, usize>::new();
    let mut next_input = 0usize;
    for (cached_index, cached) in eligible.iter().enumerate() {
        let Some(relative_index) = items[next_input..]
            .iter()
            .position(|item| cached_item_matches_input(cached, item))
        else {
            continue;
        };
        let input_index = next_input + relative_index;
        matches.insert(input_index, cached_index);
        next_input = input_index + 1;
    }

    if matches.is_empty() {
        let restored = eligible.len();
        let mut merged = Vec::with_capacity(restored + items.len());
        merged.extend(eligible.iter().cloned());
        merged.extend(items);
        return (merged, restored);
    }

    let last_match = matches.keys().copied().max().unwrap_or(0);
    let mut merged = Vec::with_capacity(eligible.len() + items.len());
    let mut cached_cursor = 0usize;
    let mut restored = 0usize;
    for (input_index, item) in items.into_iter().enumerate() {
        if let Some(&cached_index) = matches.get(&input_index) {
            while cached_cursor < cached_index {
                merged.push(eligible[cached_cursor].clone());
                cached_cursor += 1;
                restored += 1;
            }
            // The explicit item wins (and may intentionally contain richer content).
            merged.push(item);
            cached_cursor = cached_index + 1;
            if input_index == last_match {
                while cached_cursor < eligible.len() {
                    merged.push(eligible[cached_cursor].clone());
                    cached_cursor += 1;
                    restored += 1;
                }
            }
        } else {
            merged.push(item);
        }
    }
    (merged, restored)
}
