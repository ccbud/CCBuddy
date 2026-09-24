# History review contract

`HistoryLibrary` is the sole owner of the derived in-memory catalog. Its six adapters
read producer files through approved roots; they never write to producer paths.

`refresh({ onEvent })` publishes zero or more progress events followed by exactly
one terminal event. A newer generation supersedes an older refresh, which then
returns `cancelled` without publishing. A source failure is visible in snapshot
diagnostics and cannot turn the library into an authoritative empty result.

`list()` returns a versioned snapshot. `load(id)` reopens the original source,
checks its canonical path and inode-sensitive fingerprint, and returns messages
from that read. A changed source updates its summary only after the new read is
verified. Callers cannot provide arbitrary paths to `load`.

The public types and runtime validators live in `src/contract.ts`. Desktop IPC
and the renderer should use those DTOs; filesystem details stay behind the port.
