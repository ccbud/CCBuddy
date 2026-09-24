# Two-pass context compaction

CCbuddy may prepare a summary of older conversation rounds before the normal
auto-compaction threshold is reached. This is a speculative first pass, not a
session mutation. The existing compaction request remains the only operation
that writes a summary message, boundary, or timeline event.

## Ownership and trigger

The Agent runtime owns at most one in-memory candidate per session. When the
current request is below the normal auto-compaction threshold but has reached
80% of it, the runtime may start a background summary of the older rounds
selected by the existing auto-compaction selector. It does so only when the
selected history contains at least two rounds and a user-configured model is
already selected. The first pass uses that same model, has no tools, and records
its provider usage separately. It must not select a default or fallback model.

The candidate contains a cloned entry snapshot, the exact model instance, and
the compaction instructions. It holds only a summary or a pending request in
memory. It is never persisted to `~/.ccbuddy`, the session transcript, or the
history index. Starting a newer incompatible candidate cancels the old request.
Stopping the turn or shutting down the session cancels a pending request.

## Commit boundary

At the actual auto-compaction threshold, the runtime may use a completed first
pass only if its model instance and instructions still match and its cloned
entries are an exact prefix of the newly selected summary entries. This prefix
check includes the context preamble, message content and metadata. The second
pass receives the current preamble, the first-pass summary as a synthetic
message, and the unsummarized tail. The normal compact operation alone validates
the final response, persists one boundary, replaces the active runtime history,
and keeps the existing recent-round preservation policy.

If the candidate is pending, failed, cancelled, stale, or mismatched, the runtime
discards it and runs the existing single-pass compaction. A failed first pass is
logged and counted as a provider request, but does not increment the auto-compact
failure breaker and does not prevent the main turn. The final pass retains its
current cancellation, retry and error behavior. A second-pass context-overflow
retry discards the prepared summary and uses the existing full-history selection
and truncation logic. No first-pass result may be committed after cancellation.

## Acceptance

- The candidate cache has one entry per runtime; repeated near-threshold checks
  do not start duplicate provider requests for a compatible prefix.
- A completed matching candidate is merged into the final request, while a
  changed message, model, instruction, or pending/failed candidate falls back
  to the existing request without changing session state.
- Cancelling or closing the session aborts the pending first pass. Its delayed
  completion cannot make it usable again.
- First-pass model usage is recorded, but only the final pass creates a compact
  boundary and summary message. No configured model means no first pass.
