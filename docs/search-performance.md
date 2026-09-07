# Local search performance

CC Buddy embeds `tgrep-core` 1.0.4 at commit
`e2007b52d2b8fe4176159d0da20c9ba4a46d5aab`, the same revision as the supplied
tgrep checkout. Cargo downloads this immutable upstream revision and locks all
transitive dependencies. A release carries arm64 and x86_64 slices of
`libccbuddy_tgrep.dylib`; the user does not install Rust or a separate CLI.

## Search path

The existing SQLite catalog remains the authoritative derived store. tgrep is
an in-process candidate generator over the catalog's normalized, visible
transcripts, including subagents. It does not crawl the producer's directories,
start a server, execute a command, or change a user's CLI configuration.

On the first eligible search without a valid checkpoint, the catalog streams
each transcript into tgrep. This initial preparation is not instantaneous and
is measured separately from restored and warm queries below.
A live overlay flushes after 64 MiB of input, and subsequent compactions use
upstream's streaming merge into memory-mapped postings. This bounds overlay
growth independently of the total archive; a single large transcript can
temporarily exceed the threshold. Original transcript text is never kept in
the tgrep index. Its files contain trigram postings and numeric SQLite IDs.

The sibling `.tgrep-v2` cache directory is set to mode `0700` before any index
data is written. Completed index files form an immutable, persistent checkpoint;
the manifest stores only numeric row IDs and SHA-256 identity fingerprints,
not paths or transcript content. Reopening validates all sealed files with
streaming BLAKE3 checksums, checks the normalization version, and reconciles
every lightweight SQLite identity before trusting the cache. This deliberately
does not trust a reused catalog generation after a database replacement.

Checkpoint publication hard-links immutable files, flushes data and directory
entries, and atomically replaces an `active` pointer. Interrupted working
merges cannot replace a committed checkpoint. Missing, truncated, corrupt, or
partially written checkpoint files cause rebuilding. Cache roots, lock files,
and pointer/metadata reads reject symlinks. A lifetime file lock admits one
publisher; a simultaneous database instance gets its own private temporary
overlay. Successful publication reclaims abandoned sealed checkpoints without
touching another instance's working directory. Working overlays are removed
on normal close; a killed process can leave a private temporary directory.
These are derived caches, not encrypted storage, and contain no plaintext
transcript copies or queries. Validation protects reopen, not arbitrary external
modification of already memory-mapped files while the app is running.

At an unchanged catalog generation, a search reads one generation integer and
queries the mmap index. It does not read the entire corpus. At a changed
generation, it enumerates small document identities and reads text only for
added or replaced transcripts. Removed IDs are pruned before the generation
becomes searchable. The generation, changed text, and candidate references are
read within one SQLite snapshot. Detail retrieval also checks the session and
transcript identities, preventing a reused SQLite row ID from attributing a
new transcript to an old search result.

Queries and documents share Foundation case folding and Unicode canonical
composition. Final matches, occurrence counts, original snippets, and UTF-16
message anchors are verified against the unchanged original text. Source,
scope, trash, canonical-session, and activity-order filters remain in force.
Common ASCII coding terms and unified Han queries use an escaped literal ICU
scanner followed by exact Foundation validation at **Swift** grapheme boundaries.
It scans cancellation-bounded 64 Ki UTF-16 windows with query-length overlap;
neither text, queries, nor occurrence counts are truncated. Rejected boundary
candidates resume one scalar later, preserving valid overlapping matches around
ZWJ and Unicode Prepend characters. Complex Unicode queries, canonical Han
aliases, and queries over 1,024 UTF-16 units retain the original Swift Foundation
path. The long-query threshold selects an algorithm, not a search-length limit.
Queries whose folded UTF-8 form contains fewer than three bytes use the literal
path. One- and two-character CJK queries use tgrep's byte trigrams. Unavailable or
failed tgrep libraries also use a bound Foundation literal matcher in SQLite;
SQLite's ASCII-only `lower()` no longer decides literal fallback matches.
Cancelled synchronization is discarded and can be retried by the next query.

`ConversationSearchDiagnostics` reports the engine actually used, total
indexed documents, candidate count, incremental document count, candidate
generation latency, checkpoint restoration, cumulative normalization/index-build
time, and fallback state. It contains no query text.

## Real local-history validation

With the owner's permission, the production loader scanned their actual
Claude, Codex, Qoder, Grok, Copilot, and Antigravity histories on an arm64
Mac16,10 with 16 GiB RAM (2026-09-07). The benchmark opened source transcripts
read-only and wrote only a disposable derived catalog on a separate workspace
volume. Original files, session titles, IDs, snippets, CLI settings, and private
paths are not included in this report or committed fixtures.

| Cold operation | Measured result |
| --- | ---: |
| Actual source files / bytes | 1,366 / 7,360,525,263 |
| Full production parse failures | 0 |
| Cold SQLite catalog import | 330.21 s |
| Catalog + WAL + SHM after import | 2,409,385,752 bytes |
| Peak process RSS during cold import | 2,442,674,176 bytes |
| Largest single source file | 458,822,422 bytes |
| Largest-file parse / messages | 6.41 s / 16,921 |
| Largest-file parse peak process RSS | 933,560,320 bytes |

The derived catalog contains 1,371 searchable transcripts, including subagents.
Cold import remains a substantial operation for this archive; the existing
background scan exposes progress. The tgrep checkpoint does not eliminate
initial parsing, nor does it make opening a hundreds-of-megabytes transcript
free. Live producer files changed between scans: a second reconciliation reused
1,358 files and reparsed 8 with zero failures, so it is not presented as a
perfectly unchanged warm-scan benchmark.

The initial implementation's first tgrep preparation took 84.33 s. Profiling
identified 69.75 s in Rust indexing, dominated by per-byte generic hashing and
excessive small full-index merges. Using upstream's optimized trigram extractor
and a 64 MiB streaming overlay reduced first candidate preparation to 21.48 s
(10.43 s normalization, 7.49 s Rust build). The sealed checkpoint occupies about
192 MiB. A separate-process reopen's first query took 324.67 ms including full
checkpoint integrity reads, mmap validation, and SQLite identity reconciliation,
with **zero** documents reindexed and zero normalization/build time.

The same frozen SQLite snapshot was also queried with its real, ready FTS5
index, not only a full-scan baseline. These are **candidate-stage** measurements,
not app-response timings:

| Public query | FTS candidates / time | tgrep candidates / time |
| --- | ---: | ---: |
| `Swift` | 571 / 33.03 ms | 668 / 3.91 ms |
| `performance` | 625 / 75.05 ms | 1,019 / 5.58 ms |

tgrep's mask-free posting intersection is fast but broader than FTS's phrase
filter, so it can require more exact document reads. A faster candidate stage
does **not** establish that tgrep is universally faster end to end. Its benefits
include Unicode-aware candidates, short CJK acceleration, persistent restart
reuse, and explicit engine/fallback diagnostics.

The final cancellation-bounded literal matcher was separately remeasured on the
unchanged documents. The old column performs only the first Foundation match;
the new column finds that same first match **and counts every nonoverlapping
occurrence**. Neither includes SQLite decoding, snippets, inference, or UI work.

| Public query | Original first-match scan | New full exact match + count |
| --- | ---: | ---: |
| `搜索` | 6.83 s | 1.59 s |
| `performance` | 9.01 s | 1.79 s |
| `Swift` | 6.07 s | 1.81 s |

Every visited document's first range passed the independent Swift Foundation
oracle. Unit differential checks additionally cover full counts, Unicode
case-fold expansions, combining marks, ZWJ/Prepend, overlapping candidates,
supplementary Han, chunk-crossing matches, long queries, and cancellation.

The final production-facade benchmark calls `IndexedHistoryRepository.search`
directly, including scope filtering, canonical ordering, folded Codex children,
exact counts, snippets, and message anchors. This archive projects to 291 visible
top-level rows; a child-only hit is attached to its parent row and retains the
child transcript key for navigation. It is not the earlier reference loop that
could stop after 200 recent, separately indexed rollout files.

| Public query | Returned rows | Child/embedded transcript hits | Repeated production search |
| --- | ---: | ---: | ---: |
| `搜索` | 104 | 10 | 2.16 s |
| `performance` | 107 | 9 | 2.27 s |
| `Swift` | 62 | 5 | 2.31 s |

These are repository timings, not UI or semantic-reranking latency. Every
returned hit had a positive complete count, nonempty snippet, and located
message anchor. After the timed calls, an independent Swift Foundation oracle
checked full counts, exact snippets, and UTF-16 anchors across 19 real-document/query
samples of at most 128 KiB across nine query runs, with no mismatches. Repeated
queries can revisit the same document; this is not a count of distinct documents.
Only this expensive validation oracle was sampled; production matching did not truncate documents
or counts. The standalone nine-query run, including validation, took 22.93 s
and peaked at 806,273,024 bytes RSS; this is not the app's steady-state footprint.
The checkpoint-restored first candidate stage took 166.29 ms in this run.

Separate live-library validation exposed search starvation: automatic catalog
reloads every 1.5 s could repeatedly cancel a longer-running exact search.
Automatic revisions now preserve the in-flight query generation, publish its
complete result, and coalesce one trailing refresh while retaining visible hits
and diagnostics. Explicit query or scope changes still cancel stale work. This
checks responsiveness under live producer writes; Debug-app observations are
not performance measurements and do not replace the frozen-catalog timings above.

Live activity and reading intent are separate: opening a search hit or jumping
within a transcript pauses automatic scrolling without stopping content updates.
The Latest action explicitly resumes following. Header statistics use the fully
loaded active transcript, so a later bounded-prefix catalog refresh cannot replace
exact message/token totals with sampled counts; catalog edits remain authoritative
for titles, tags, and other non-statistical metadata.

The corpus also exposed a CJK regression inherited from SQLite FTS's
three-character gate: the two-character query `搜索` previously scanned the
whole catalog in 64,546 ms. tgrep uses UTF-8 byte trigrams; the corrected gate
generated candidates in 4.09 ms on the same derived corpus. This is a candidate
stage measurement, not end-to-end UI latency. Exact matching, occurrence
counts, document decoding, snippets, and semantic reranking are separate work.

By default, the benchmark emits aggregate timings and fixed public query terms only.
The explicit `--show-roots` option also prints private source paths for local
inspection; do not publish that output.

```sh
bash native/Scripts/benchmark-real-history.sh --inventory
bash native/Scripts/benchmark-real-history.sh --largest
bash native/Scripts/benchmark-real-history.sh --run
```

`--queries --catalog <benchmark.sqlite3>` can reuse a benchmark-owned private
snapshot to compare first preparation with a second-process checkpoint reopen.
`--baseline-fts` compares ASCII queries with `enableTgrep: false` on that same
snapshot; the emitted `engine` identifies whether FTS was actually available
and ready rather than silently calling a literal scan an FTS comparison.
`--queries --repository --catalog <benchmark.sqlite3>` runs the actual production
facade and the post-timing Foundation sample oracle, without starting watchers
or reconciliation. Any parity mismatch makes the benchmark fail. All these
snapshot modes require the explicitly named, private benchmark-owned derived
database; they do not accept a live application's catalog.

## Reproducing the bridge checks

```sh
cargo test --manifest-path native/TgrepBridge/Cargo.toml --locked --release
cargo test --manifest-path native/TgrepBridge/Cargo.toml --locked --release \
  benchmark_warm_phrase_candidates -- --ignored --nocapture
CCBUD_TGREP_ARCH=universal bash native/Scripts/build-tgrep.sh
```

The optional bridge microbenchmark uses a generated 2,000-document corpus and
compares repeated candidate queries with Rust literal scans. It is not a
comparison with SQLite FTS or an end-to-end app speed claim; the real archive
measurements above are the representative integration evidence.

The hosted `TgrepSearchIndexTests` verify that the packaged library actually
loads, Foundation-equivalent Unicode matching, warm searches with zero
transcript re-indexing, one-document incremental updates, stale-row deletion,
row-ID reuse, scope/trash/subagent filtering, NUL-safe literal fallback, and
candidate sets larger than the 400-parameter SQLite batch size. Rust bridge
tests additionally cover disk/overlay merges, sealed checkpoint recovery,
unpublished working changes, concurrent publication leases, truncated postings,
symlink protection, and private cache cleanup. Hosted tests cover restart with
zero reindexing, same-generation SQLite recreation, damaged manifests, and
symlink rejection with exact Unicode fallback.
