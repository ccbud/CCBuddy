# Historical search performance — retired SQLite architectures

This is an archived engineering record, not the current architecture or benchmark
instructions. Its measurements and references to a "current" schema describe the
earlier SQLite-backed implementations. See [current search architecture](search-performance.md)
for the file catalog that replaced them. Historical benchmark flags below are retired.

CC Buddy embeds `tgrep-core` 1.0.4 at commit
`e2007b52d2b8fe4176159d0da20c9ba4a46d5aab`, the same revision as the supplied
tgrep checkout. Cargo downloads this immutable upstream revision and locks all
transitive dependencies. A release carries arm64 and x86_64 slices of
`libccbuddy_tgrep.dylib`; the user does not install Rust or a separate CLI.

## Search path

The SQLite catalog remains the authoritative derived store. tgrep is
an in-process candidate generator over the catalog's normalized search
projections, including subagents. It does not crawl the producer's directories,
start a server, execute a command, or change a user's CLI configuration.

The current schema stores logical transcript identity separately from physical
search blocks. Blocks target 32 KiB of UTF-8 and split only at Swift `Character`
boundaries; an indivisible larger grapheme is the one oversized-block exception.
Each byte has one stored owner. The body is independently LZFSE-compressed, or
stored raw when compression would not reduce it, with transcript-global UTF-16
coordinates and intersecting message spans. There is no second full-text column
or FTS index in the completed schema. Compression is not encryption.

Global search is not an unrestricted scan of every byte in the original files.
The existing catalog projection retains at most 32 KiB of UTF-8 search text per
message, with 16 KiB limits for individual thinking/tool/raw blocks before the
whole-message limit is applied. These limits include a truncation marker and
preserve complete grapheme clusters. Injected user transport text is excluded.
Both tgrep verification and literal fallback search this same stored projection;
neither can find a phrase omitted when the projection was built. In-session find
instead uses the fully loaded normalized transcript's visible text, without these
catalog byte limits; it still follows the reader's content and tool-pairing rules,
not raw-file byte-search semantics.

On the first eligible search without a valid checkpoint, the catalog streams
decoded blocks into tgrep, each with up to 64 following `Character`s of lookahead.
Only a scalar-aligned, at-most-64-byte normalized query prefix drives the candidate
index; the full original query remains the exact-match authority. Lookahead is
assembled during reads rather than stored as duplicate body text. Exact refinement
reads candidate blocks with query-sized lookahead, counts a match only in the block
owning its start, and carries nonoverlapping-match progress across block boundaries.
Long queries are not truncated during verification. This initial preparation is not instantaneous and
is measured separately from restored and warm queries below.
A live overlay flushes after 64 MiB of input, and subsequent compactions use
upstream's streaming merge into memory-mapped postings. This bounds overlay
growth independently of the total archive; one indivisible block and its lookahead
can exceed the target. Original transcript text is never kept in the tgrep index.
Its files contain trigram postings and numeric SQLite block IDs.

The sibling `.tgrep-chunks-v1` cache directory is set to mode `0700` before any index
data is written. Completed index files form an immutable, persistent checkpoint;
the manifest stores only numeric block IDs and SHA-256 identity fingerprints,
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
touching another instance's working directory. Each new working directory has a
private, single-link lease file bound to the cache-root and workspace device/inode
identities. Its process holds an exclusive advisory lock for the workspace lifetime.
A separate short-lived registry lock serializes workspace creation and recovery.
Publishers and secondary instances can reclaim a dead peer's unlocked, validated
workspace without waiting for checkpoint publication. Recovery does not use PID
or age guesses: live leases, legacy unmarked directories, malformed identity
markers, symlinks, nonprivate permissions and unsupported filesystem nodes are
not treated as abandoned caches. Directory-relative, no-follow traversal checks
identities before deletion; the lease is removed last so interrupted cleanup can
be retried. Normal close also removes its own workspace while holding the lease.
These are derived caches, not encrypted storage, and contain no plaintext
transcript copies or queries. Validation protects reopen, not arbitrary external
modification of already memory-mapped files while the app is running.

At an unchanged catalog/storage revision, tgrep candidate lookup reads one revision
integer and queries the mmap index without rereading the corpus. Exact matching
still decodes candidate blocks; common terms can cover much of the corpus. At a changed
revision, it enumerates small block identities and reads text only for
added or replaced blocks. Removed IDs are pruned before the revision
becomes searchable. The generation, changed text, and candidate references are
read within one SQLite snapshot. Detail retrieval also checks the session and
transcript identities, preventing a reused SQLite row ID from attributing a
new transcript to an old search result.

Queries and documents share Foundation case folding and Unicode canonical
composition. Final matches, occurrence counts, snippets, and UTF-16
message anchors are verified against the unchanged stored projection, not the
folded tgrep text or a new read of the original file. Source,
scope, trash, canonical-session, and activity-order filters remain in force.
Common ASCII coding terms and unified Han queries use an escaped literal ICU
scanner followed by exact Foundation validation at **Swift** grapheme boundaries.
It scans cancellation-bounded 64 Ki UTF-16 windows with query-length overlap;
the scanner adds no further document truncation or query/count cap. Rejected
boundary candidates resume one scalar later, preserving valid overlapping matches around
ZWJ and Unicode Prepend characters. Pure Han queries include canonically equivalent
compatibility ideographs in their regex character classes, with Foundation remaining
the authority for each candidate. Complex Unicode queries and queries over 1,024
UTF-16 units use cancellation-bounded Foundation windows. The long-query threshold
selects an algorithm, not a search-length limit.
Queries whose folded UTF-8 form contains fewer than three bytes use the literal
path. One- and two-character CJK queries use tgrep's byte trigrams. Unavailable or
failed tgrep libraries use the same exact matcher over sequential decoded blocks;
SQLite's ASCII-only `lower()` does not decide literal fallback matches. There is
no FTS fallback or query-time creation of an FTS index.
Cancelled synchronization is discarded and can be retried by the next query.

`ConversationSearchDiagnostics` reports the engine actually used, total
indexed blocks, incremental block count, candidate generation latency, checkpoint
restoration, cumulative normalization/index-build time, and fallback state.
Candidate counts describe indexed blocks on the tgrep path, but logical transcripts
on literal fallback; an unconverted legacy transcript contributes one candidate in
a mixed migration snapshot, not its as-yet-unindexed block count. Diagnostics contain
no query text.

### Resumable migration and delivery (2026-09-09)

Opening a legacy catalog installs lightweight identity/migration metadata; it does
not synchronously rewrite the entire body store. Idle maintenance first commits
legacy-text conversion in resumable passes, targeting at most 128 blocks
or 250 ms of block conversion. The budget is checked between blocks, not a hard
wall-clock deadline: one indivisible oversized grapheme, slow I/O or header decoding
can exceed it. Each block transaction persists byte, UTF-16 and ordinal
progress. An interrupted giant transcript resumes at the committed offset. Until a
transcript is complete, searches use bounded legacy reads; converted transcripts
use compressed blocks. Migration reads only the existing derived SQLite text, not
the producer history. A storage revision invalidates block-index state without
pretending that unchanged transcript content is a new semantic catalog generation.

The legacy body table is removed only after all documents are converted; the
obsolete FTS index is then dropped. Activity requests a yield after committed text
blocks and does not roll back useful work. The atomic FTS drop is interrupted only
by stop/lifecycle cancellation, not ordinary file activity, which would otherwise
restart a large drop indefinitely. It can occupy the background writer for longer
than a conversion pass: concurrent WAL metadata/search reads remain available while
new writes may queue.

Low-space guards, cancellable SQLite work, WAL checkpoints and durable pending
flags govern cleanup. New catalogs use incremental vacuum; a sufficiently wasteful
old catalog may require a one-time, capacity-guarded full vacuum to adopt that mode.
Incremental reclamation commits 256-page microbatches, then checks activity and a
cooperative 250 ms reclamation budget. A microbatch must reach SQLite completion
before yielding, and pending remains set until the freelist is drained. Neither
that budget nor the conversion budget is a hard wall-clock limit. The separate
FTS-drop and one-time full vacuum operations are cancellable but are not promised
to finish within either budget. A low-space or busy pass must not be reported as
completed migration.

Progressive search first publishes openable hits with verified identity, first
match, snippet and message anchor. An incomplete count is a real lower bound, marked
`isCountComplete: false`, never an estimate. Ordered result identities and their
first-match presentation stay stable within one snapshot while remaining rows arrive
and counts complete. Counts never decrease; the completed callback and final-only
API contain full exact counts. This avoids waiting for a giant transcript's complete
count before the first usable result. Cache hits can already have complete counts.
The repository and palette share the same activity-descending, stable-ID-ascending
search order, with a source-path tie-breaker for duplicate IDs. This order is applied
before the hit limit and before publishing prefixes; ordinary catalog ordering is
unchanged. Without this shared policy, tied sessions could be reversed in the UI
as each batch arrived, shifting the retained selection into the middle of the list.
Candidate preparation, first visible publication, first complete count and complete
search are separate metrics; none measures frame paint.

## Real local-history validation

### Compressed-block snapshot (2026-09-09)

The owner's stable, stopped preview catalog was copied with SQLite backup, including
its committed WAL. Only that private derived copy was migrated and queried. No raw
history, catalog, title, session identifier, path or screenshot is included in the
repository. This is a different snapshot from the historical measurements below;
the numbers must not be presented as a controlled before/after latency speedup.

An independent read-only verifier, importing no application code, checked all
1,571 session rows (including raw metadata bytes), 1,458 logical transcripts,
25,216 chunk ordinals/UTF-16 layouts and 324,441 unique message spans. Streaming
SHA-256 matched every transcript: 800,222,570 decoded bytes before and after,
229,758,399 stored body bytes after compression. All identity, body, metadata,
span, layout and state mismatch counts were zero. Three content-stamp rebases
matched exactly the migration's identity-trigger mapping. The final catalog had
no FTS or legacy-body table, no freelist pages and no pending maintenance.

| Storage on the same private snapshot | Bytes |
| --- | ---: |
| Before: legacy SQLite + WAL + SHM, excluding any old tgrep cache | 4,277,129,216 |
| After migration: SQLite + WAL + SHM | 301,764,608 |
| After index publication and process close: SQLite + tgrep, unique file inodes | 1,103,203,033 |
| Same final files: allocated inode blocks | 1,116,127,232 |

SQLite alone is 92.9% smaller. The completed SQLite-plus-tgrep snapshot is 74.2%
smaller than even the old SQLite-only baseline. Hard-linked checkpoint files are
counted once by device/inode, not once per directory entry; allocated blocks are
not an APFS clone-exclusive storage claim. There were zero working directories
after normal process close. This snapshot did not include an older `.tgrep-v2`
cache: these figures do not promise automatic deletion of legacy, unmarked caches
in an existing installation.

Two optimized production-repository processes queried the same migrated catalog.
The first had no tgrep checkpoint; the second restored the published checkpoint.
Scope resolution prewarmed metadata, exposing 331 canonical live sessions across
seven physical roots. The index covered all 25,216 stored blocks. The system's
filesystem cache was not flushed or controlled. Times below measure repository
callbacks, including callback contract validation, not Store delivery or frame paint.

| Query and state | First openable hit | First complete hit count | Entire result count complete |
| --- | ---: | ---: | ---: |
| 系统代理: first search, no checkpoint | 49,901.8 ms | 49,992.2 ms | 50,000.0 ms |
| 系统代理: first search after process restart | 603.5 ms | 779.1 ms | 789.6 ms |
| 当前版本: first use of keyword, in the two prepared-index processes | 31.5–56.6 ms | 157.9–350.1 ms | 242.0–475.6 ms |
| 系统代理: repeated, exact-result cache populated | 17.5–19.1 ms | 17.5–19.1 ms | 25.2–27.5 ms |
| 当前版本: repeated, exact-result cache populated | 18.7–18.9 ms | 18.7–18.9 ms | 26.4–27.0 ms |

These are individual observations, not percentiles. The first search's 49,884.9 ms
candidate preparation includes 8,712.7 ms cumulative normalization and 32,827.1 ms
trigram construction. That initial setup remains substantial; it is not hidden
inside a warm-query claim. Restored preparation was 586.7 ms with zero normalization
or trigram rebuild. Peak process RSS was 1,004,863,488 bytes for initial construction
plus all queries, versus 73,891,840 bytes in the restored process.

Both runs returned eight canonical sessions / 172 occurrences for 系统代理 and
48 sessions / 475 occurrences for 当前版本. Every first-time keyword published a
verified lower bound before completing counts. Callback identity/anchor/snippet
prefixes remained stable, counts never decreased, and all final counts were complete.
The final-only API agreed after each timed call. Beyond the benchmark's small sampled
oracle, a separate read-only harness compared whole-original-text Foundation matching
against production chunk decoding/matching for **every** logical document, outside all
performance measurements. Across all 1,458 transcripts, 系统代理 matched 22 documents /
351 occurrences and 当前版本 matched 165 documents / 858 occurrences, with zero
per-document count or first-UTF-16-offset differences. These raw catalog totals include
hidden/deleted/nested transcripts and are not the canonical visible-session totals above.
An independently built tgrep index included every expected match-start-owning block:
106 of 211 candidates for 系统代理 and 436 of 486 for 当前版本, with zero missing blocks.
That validates the postings superset independently; it is not an additional run of the
production candidate SQL path or a full snippet oracle.

Paths, identifiers, mixed-script phrases and common terms were also exercised.
In the restored process, `ConversationIndexDatabase` delivered first/final results
in 30.4/192.0 ms, `native/Sources` in 230.7/1,170.9 ms and `Swift 代码` in
40.3/336.0 ms. A very common `error` query covered 21,420 candidate blocks and
125,392 occurrences in the 200 returned sessions: first publication took 443.4 ms
and full counting 4,122.3 ms. Progressive delivery does not make corpus-wide exact
counting instantaneous, remove the 200-result cap or expand the stored projection.

The final Debug app module was also exercised through the real
`HistorySessionLoader → ConversationStore.select → PreparedTranscripts → detail search`
chain, using the largest actual source (458,822,422 bytes, 16,921 normalized messages,
8,888 visible rows). An isolated provider selected real large/small histories without
starting a gateway or changing any original file. Integrity hashing pre-read the files,
so these are not cold filesystem-cache results.

| Actual Store operation | Elapsed | Maximum MainActor heartbeat gap |
| --- | ---: | ---: |
| Initial large-session load and UI-data projection | 6,391.6 ms | 16.8 ms |
| In-session 系统代理: 2 messages / 7 occurrences | 811.3 ms | 11.8 ms |
| In-session 当前版本: 16 messages / 18 occurrences | 731.3 ms | 11.1 ms |
| Switch to small session while a search is still active | 7.2 ms | 7.2 ms |
| Reopen the large session | 6,321.7 ms | 15.1 ms |
| Refresh an appended private small-session copy | 99.0 ms | 11.1 ms |

Detail timings include the production 90 ms debounce. Every matching message and
occurrence count agreed with a separate Foundation visible-text oracle, run outside
timing; first/next/previous navigation and rejection of stale search completions passed.
The detail text cache remained at its 8 MiB bound. Appending only to the private copy
added one message and two occurrences, correctly reflected by refresh and automatic
research. SHA-256, size and modification time of both original sources were unchanged.
The 10 ms heartbeat measures main-actor availability, not visual FPS or frame paint.
Loading a half-gigabyte transcript still costs seconds even though the main actor remains
responsive; this test does not claim instantaneous detail loading or replace native UI E2E.

Final local native regression ran all 868 tests successfully, with zero skipped tests
and no retries, including all 11 real Bifrost/CLI integration cases. It caught and fixed
an initialization-order issue: a fresh catalog must select incremental vacuum **before**
enabling WAL, otherwise SQLite retains non-reclaiming mode 0. The two reclamation
regressions then passed with mode 2 and committed 256-page reclamation batches.
The unsigned universal package passed all eight required self-checks, including real
tgrep matching and bundled semantic inference under the CPU+ANE compute policy.

Local UI launch diagnostics separately identified cross-process fixtures in the runner's
protected temporary directory. Fixtures use unique, atomic mode-0700 directories within
XCTest's permitted temporary root; directly writing the shared `/private/tmp` root is
not permitted by the CI runner's sandbox. No privacy, sandbox or signing policy was changed.
The final local runner attempt timed out enabling system automation before executing any
UI case, so that attempt is not counted as a UI pass. The PR's clean macOS CI supplies
the complete, zero-skip native UI gate and exact-head verification record.

### Historical whole-transcript measurements (2026-09-07–08)

The dated measurements below record the previous whole-transcript/FTS-era schema
on September 7–8. They preserve the observed baseline and its limitations; they
are not measurements of the September 9 compressed-block architecture. The newer
private snapshot has 1,571 catalog rows, 802.8 MiB allocated to the legacy body table, 3,233.5 MiB
in the old FTS data table and 1,044,213 SQLite pages before migration. Its changed
sample must not be compared with the earlier row counts as a controlled speedup.

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
| Largest-file load including catalog projection / messages | 6.41 s / 16,921 |
| Largest-file load peak process RSS | 933,560,320 bytes |

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
192 MiB. A separate-process reopen's first candidate lookup took 324.67 ms including full
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
unchanged stored search documents. The old column performs only the first
Foundation match;
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
Only this expensive validation oracle was sampled; production matching added no
truncation beyond the stored catalog projection and counted all occurrences within it.
The standalone nine-query run, including validation, took 22.93 s
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

### Live-profile regression audit (2026-09-08)

The frozen external-volume benchmark above did **not** establish responsiveness
in the user's normal running Release app. A subsequent self-test exposed a
`当前版本` query taking **115,876.9 ms** for 48 results. A five-second process
sample found the search worker inside SQLite's literal-match function and
Foundation case-insensitive `String.range`; the catalog coordinator was waiting
for that query's shared read lock. A second sample while testing `系统代理`
confirmed the same fallback path and queued searches/list loads. The main thread
was mostly idle during these samples: this was slow result delivery and lock
contention, not evidence of an ANE or main-thread inference stall.

The app had loaded its bundled tgrep library, but the normal profile had no
usable persistent checkpoint. Unlike the benchmark catalog on the external
volume, the normal catalog and all tgrep merge work used the system volume,
which had only about 400 MiB available. The code discarded the native error and
permanently disabled tgrep after a single failure; that state also disabled FTS.
Low disk space is a strong suspected trigger, **not a recovered ENOSPC error**.
The silent permanent fallback and the expensive literal scan are established
independently of the original failure's cause.

The same audit found that detail-only loads unnecessarily built and discarded
an entire catalog search projection, and that transcript projection and in-session
find performed repeated whole-transcript work on the main actor. These paths
must be covered independently of parser-only and candidate-only benchmarks.
Acceptance should include cache failure/recovery, rapid query replacement,
large-transcript first readable content, exact tail-hit navigation, and return
to a small session. A fixture that blocks cache-directory creation tests a real
initialization failure; it must not be described as a physical disk-full test.

### Follow-up measurements and behavior (2026-09-08)

The follow-up used a private read-only backup of the live catalog, containing
1,413 physical session rows and 331 visible canonical sessions. Source histories
and the running app's online catalog were not modified. Snapshot scope resolution
prewarmed the metadata cache. The original Release app continued running during
these measurements and was observed consuming substantial CPU; these are not
controlled, isolated UI benchmarks or a same-storage comparison with the 116 s
live-app observation.

The snapshot was queried as stored, without reimporting the source files. A legacy
catalog may retain older projections with different bounds until reindexing, so
these corpus timings and counts do not establish fresh-index coverage of text
beyond the current per-message limits. The fallback UI fixture separately builds
a fresh index from many messages below the limit, with the Chinese phrases in a
distinct final message; it does not rely on searching a clipped giant message.

At that stage, search published an ordered prefix as soon as the first result had its **full**
exact count within the stored projection, snippet and message anchor. Later batches
only extended that prefix; the September 9 path above separates first visibility
from count completion. The final-only API remains authoritative. Query/run generation guards prevent late
callbacks from replacing a newer query, a cleared palette or a completed result.
Automatic catalog refreshes retain already visible results. The UI reports candidate,
first-result publication and full-search times separately; publication is not frame paint.

| Query / persistent checkpoint state | First complete repository hit | Complete repository search | Rows / exact occurrences |
| --- | ---: | ---: | ---: |
| `系统代理`, separate-process restore | 206.50 ms | 6,392.25 ms | 8 / 46 |
| `当前版本`, warm | 215.15 ms | 4,049.91 ms | 50 / 309 |
| `系统代理`, repeat | 184.66 ms | 5,478.03 ms | 8 / 46 |
| `当前版本`, repeat | 206.37 ms | 4,021.33 ms | 50 / 309 |

All four runs validated cumulative-prefix monotonicity, complete-callback parity
and identical final ordering/counts/snippets/anchors against the final-only API.
Lightweight callback validation was included in each progressive timing. After
each timed query, one untimed final-only search and the bounded Foundation oracle
ran before the next query. These checks can warm filesystem/database caches and
accelerator state for later queries and repeats; no oracle search preceded the
first timed query.
The restored candidate stage took 165.45 ms; warm candidates took 31–33 ms.
The complete benchmark, including untimed final-only validation searches, peaked
at 681,181,184 bytes RSS. The independent Foundation oracle was limited to small
real documents (two samples total here); it is not a full-corpus independent oracle.

There are still important limits. An earlier cold build of this snapshot took
37.76 s end to end, including 32.53 s candidate preparation. Progressive delivery
does not bypass that cold preparation. Blocking the cache directory with a regular
file exercised the real `unsafeCache` failure: complete literal fallback queries
took 12.23–13.62 s, with the same counts over the stored projection. Fallback is
exact and cancellable, not instantaneous. These earlier measurements used the same
snapshot but separate runs, before the progressive delivery measurement above.

Native failures now expose privacy-safe reason codes, a low-space cold-build
preflight and a 30 s subsequent-query retry cooldown instead of permanently
disabling acceleration. Literal fallback reuses the optimized matcher and releases
its SQLite reader on cancellation. A content-only stamp prevents metadata refreshes
from repeatedly reindexing unchanged large transcripts. Neither a low-space
preflight nor the 64 MiB input overlay is a guaranteed bound on merge disk usage.

Detail-only loading skips the discarded catalog projection. Visible rows, tool
pairs, transcript tabs and navigation are prepared off the main actor. In-session
find is debounced, cancellable and generation-guarded, with an 8 MiB prepared-text
cache; the cache budget does not truncate the searched visible text or its
occurrence counts. Messages too large to cache are still searched in full. The
budget covers retained UTF-8 search text, not total transcript memory, transient
preparation or process RSS. The lazy timeline iterates prefiltered visible indices
rather than a conditional child per message.

The largest real source (458,822,422 bytes, 16,921 messages) loaded through the
updated production detail loader in **4,879.66 ms**, with 761,430,016 bytes peak
process RSS. This excludes Store projection, Markdown layout and UI rendering;
it establishes neither subsecond opening nor a measured selection-to-first-paint
speedup. Source discovery ran before the timed load, and filesystem caches were
not flushed; this is not a guaranteed cold-disk measurement. The earlier 6.41 s
load also constructed a catalog projection and used the previous day's live
corpus, so it is not a controlled like-for-like speedup baseline. The current
inventory was 1,377 files / 7,666,776,681 bytes; live producer
activity explains its difference from the previous day's inventory.

#### Real-history desktop checks

The follow-up desktop test used the same seven configured local agent-history
roots, a private system-volume catalog/profile, and a distinct local test bundle
identifier. The user's running gateway, source files and online catalog were left
intact. The test profile disabled gateway startup, CLI connections and updates;
it did not substitute generated histories for these desktop checks.

On the `e6b7df8` Release build, the first cold `系统代理` search took 64,393.2 ms
end to end. A later warm `当前版本` search reported 50.1 ms candidates, 589.2 ms
to the Store's first verified publication, and 7,585.8 ms to complete. Other warm
live runs completed in roughly 7–8 s. Live indexing and other local agents were
active; these are observed desktop diagnostics, not an isolated benchmark or
measured frame-paint latency. The cold-start limit remains material.

The desktop actually opened the 458 MB / 16,921-message source, found
`系统代理` (2 matching messages / 7 occurrences), replaced the query with
`当前版本` (16 messages / 18 occurrences), wrapped Previous to the last match,
and used Latest to reach message 16,920. Starting a broad find and switching to
a two-message session cleared the old query and navigation state. Automation
settling time is intentionally not reported as search or rendering latency.

The check also caught a diagnostics consistency bug: a background refresh could
pair the original cold first-publication time with a later warm completion time.
Both displayed timings now refer to the same search run, with regression coverage.
This corrects measurement reporting; it is not itself a search speedup.

The next rendering pass prepares Markdown structure, inline attributes and query
highlights on a cancellable per-view worker. Query changes reuse the current base
formatting; newer text never displays an older source's highlights. Disappearance
drops derived text caches while retaining one serial worker so rapid reappearance
cannot fan out giant parses. Native indeterminate feedback reports actual opening,
candidate and refinement stages, offers cancellation, and uses a static indicator
with Reduce Motion. It has no timer that redraws the transcript per frame.

Tool cards reuse source-versioned presentations, avoid encoding collapsed raw
JSON, and compute collapsed result byte summaries without joining the full body.
Their per-block derived-text budget is 256 KiB; oversized expanded content is
returned intact rather than clipped. Derived caches are released offscreen. These
changes remove repeated preparation, but do not claim to virtualize the layout of
a single giant expanded paragraph, code block or table.

An additional 2 MiB / 2,048-entry exact-refinement LRU retains only small hit or
no-match answers, not document text or message-span arrays. A short SQLite read
snapshot validates catalog generation and row identity before reuse; metadata,
scope and parent ownership are rebound on every search. Any catalog revision
(including metadata-only or live updates) conservatively invalidates entries.
Thus it helps repeated queries on an unchanged catalog, not first-time queries
or continuous revision refreshes. The accounting covers retained key/result bytes
and an overhead allowance, not total process RSS.

On the same private 1,413-row / 331-visible-session snapshot, the refinement-cache
follow-up measured the following repository-path results. There was no concurrent
build/test benchmark; the normal gateway app and real-history desktop test app
remained active. The metadata cache was prewarmed by scope discovery and the tgrep
checkpoint was restored. Filesystem caches were not flushed.

| Query / refinement cache state | First complete hit | Complete search | Rows / occurrences |
| --- | ---: | ---: | ---: |
| `系统代理`, first pass for this query | 223.12 ms | 6,583.38 ms | 8 / 46 |
| `当前版本`, first pass for this query, warm process | 82.78 ms | 4,247.72 ms | 50 / 309 |
| `系统代理`, repeated unchanged snapshot | 28.87 ms | 40.00 ms | 8 / 46 |
| `当前版本`, repeated unchanged snapshot | 19.04 ms | 28.27 ms | 50 / 309 |

Every run passed progressive-prefix and final-only ordering/count/snippet/anchor
parity. As above, the untimed final-only oracle ran after each timed query and can
warm the cache before the repeat. The independent Foundation oracle covered two
small-document samples total, not necessarily distinct documents or the entire corpus. Peak process RSS was
322,666,496 bytes. These are repository delivery timings, not UI paint latency;
live catalog changes invalidate the reuse demonstrated by the repeat rows.

The updated Universal Release (local build 99) repeated the real desktop long-
session checks after the asynchronous-rendering changes: both Chinese finds,
Previous wrapping, manual scrolling away and back without an old search pulling
the view back, Latest through message 16,920, and a broad find interrupted by
opening a two-message session. The in-session working indicator was observed
before counts appeared, and no preparation placeholder remained at the settled
checked anchors. This validates those observed paths, not every possible giant
Markdown layout. A global result also opened its real transcript and reached
prepared content containing the query.

In that live build, `当前版本` showed an openable verified result while the
remaining results were still refining; diagnostics reported 36.0 ms candidate
lookup, 363.5 ms first Store publication and 6,475.2 ms completion. A first
`系统代理` search in this process completed in 11,103.5 ms, while a later
automatic refresh reported 583.9 ms. These used the actively changing system-
volume test profile (1,458 physical rows in diagnostics), not the unchanged
benchmark snapshot. No build or XCTest run overlapped these global-search
observations, but the original gateway app and other local agents remained active.

The full CI UI suite subsequently exposed a live-following regression that the
static long-session checks did not: asynchronous prose changed lazy-row heights
after Latest's initial scroll, leaving a 62-message transcript before its true
tail. The same public live-append fixture reproduced this in the local Release.
Latest now follows actual content-size changes with coalesced, nonanimated layout
corrections. Corrections require the current file/transcript/follow revision;
native user scrolling immediately revokes them and any pending first-hit navigation.
There are no timed retries and ordinary scroll-offset changes do not trigger work.

The local build 100 repeated the same 60→62→64-message fixture: the early search
anchor survived the first append, Latest reached the actual final answer, and the
next append stayed at the tail. Scrolling up two pages then appending to 66 messages
kept the same visible message range; another explicit Latest returned to the new
tail. This controlled fixture supplements, rather than replaces, the real local
agent-history checks above.

The follow-up local regression passed all 815 non-helper native tests, including
the four layout-intent tests and the delayed-find/manual-scroll regression.
The universal Release build 100 also passed its packaged self-check (including
tgrep and offline CPU+ANE inference) and single-instance handoff check.

Final CI screenshot review caught a separate footer-clearance issue: the floating
Latest controls covered the final message's token metadata. The 68-point clearance
now belongs to the bottom scroll target itself, rather than outer padding excluded
by anchor alignment. The live-follow UI test retains its original assertions and
also captures the first Latest position for visual review.
Local Release build 101 visually verified the complete footer after Latest and
after the public fixture grew from 66 to 68 messages; its packaged self-check and
single-instance handoff both passed again.

All reported peak RSS values are process-lifetime high-water marks, not current
resident memory or exact allocations attributable to one operation. Subtracting
the emitted baseline peak from the later peak does not measure allocation volume.

## Running the current benchmark

By default, the benchmark emits aggregate timings and fixed public query terms only.
The explicit `--show-roots` option also prints private source paths for local
inspection; do not publish that output.

```sh
bash native/Scripts/benchmark-real-history.sh --inventory
bash native/Scripts/benchmark-real-history.sh --largest
bash native/Scripts/benchmark-real-history.sh --detail
bash native/Scripts/benchmark-real-history.sh --run
```

All supplied-catalog modes require a regular, single-hardlink, current-user-owned
file named `benchmark.sqlite3`, directly inside a current-user-owned private
`native/build/ccbuddy-query-benchmark.<suffix>/` directory. Symlink aliases and live
application catalogs are rejected. Create a consistent private copy with SQLite's
backup API, not a filesystem copy of a running WAL database. The storage probe may
initialize WAL sidecars on this private copy, but its connection is query-only and
never creates a missing catalog. No supplied-catalog mode starts discovery,
producer imports, watchers or reconciliation.

`--migrate --catalog <private benchmark.sqlite3>` explicitly runs pending derived
storage migration on that copy, emits anonymous progress and finishes only when
maintenance, legacy rows and legacy tables are gone. The default deadline is one
hour; `--migration-timeout-seconds` accepts a positive limit up to two hours. Three
consecutive passes without observed progress fail with a privacy-safe blocked
reason rather than spinning forever or declaring success under low disk space or
locking. All errors exit nonzero with an anonymous type/reason, not a stack trap
containing private paths. Prefer migration-only first, then new query processes, to
keep migration cost out of first-query timing:

```sh
bash native/Scripts/benchmark-real-history.sh --migrate \
  --catalog native/build/ccbuddy-query-benchmark.EXAMPLE/benchmark.sqlite3
bash native/Scripts/benchmark-real-history.sh --progressive-repository \
  --catalog native/build/ccbuddy-query-benchmark.EXAMPLE/benchmark.sqlite3
```

`EXAMPLE` is a placeholder for an existing validated private backup, not a directory
the script populates with live data. Storage output includes SQLite page/freelist
metadata and final logical-document, physical-block and compressed/decoded body
totals. Disk accounting uses `lstat` and deduplicates regular files by device/inode
across the database, WAL/SHM and both old/new tgrep cache directories. Hard-linked
working/checkpoint files count once. `unique_inode_allocated_bytes` sums
`st_blocks * 512`; it is not an APFS clone-exclusive or whole-volume space metric.
Symlinks are skipped, and no transcript BLOBs, filenames or contents are emitted.

`--queries --catalog <private benchmark.sqlite3>` reuses the copy to compare first
preparation with a second-process checkpoint reopen. `_first_query_warm_index`
means the first timed use of that term after index preparation, not a repeated-query
cache hit; `_repeat_query` is explicitly separate. `--baseline-fts` is retired and
fails explicitly: the current schema no longer maintains FTS, and historical FTS
numbers above are not silently substituted with literal fallback timings.
`--queries --repository --catalog <benchmark.sqlite3>` runs the actual production
facade and the post-timing Foundation sample oracle, without starting watchers
or reconciliation. Any parity mismatch makes the benchmark fail.

`--progressive-repository --catalog <benchmark.sqlite3>` measures the fixed terms
`系统代理`, `当前版本`, `native/Sources`, `ConversationIndexDatabase`, `Swift 代码`,
`error`, `搜索`, `工具`, `代码`, `performance` and `Swift`, then repeats the first two.
Only `系统代理` and `当前版本` require nonempty results in the owner-authorized corpus;
the other public terms may legitimately be absent. Every callback checks stable
prefix identity/anchor/snippet, nondecreasing counts and irreversible count completion.
The completed result must have all counts complete and exactly equal the untimed
final-only API, which runs after the timed progressive call. That oracle can warm
later queries and repeats. Output separates first visible hit from first complete
hit and records the first-hit phase/count-completeness flag.

`--fallback-repository` requires a private
snapshot without an existing tgrep cache and installs a temporary regular-file
obstacle at the `.tgrep-chunks-v1` path; it does not simulate an actual full disk.
Cleanup removes only that unchanged owned obstacle. `--detail` measures the largest
authorized real source through the production detail loader, excluding Store
projection and UI first paint. Do not compare it to selection-to-visible latency.

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
symlink protection, and private cache cleanup. Real subprocess tests kill publishers
and secondary readers, recover unlocked workspaces without disturbing live peers,
and preserve the last committed checkpoint after unpublished flushes. Threaded
creation/recovery exercises the registry bootstrap race; a duplicated-descriptor
test covers prompt publisher-lock release despite inherited open-file descriptions.
Unmarked, moved, hardlinked and malformed workspace fixtures are retained or rejected
conservatively. Hosted tests cover restart with
zero reindexing, same-generation SQLite recreation, damaged manifests, and
symlink rejection with exact Unicode fallback.
