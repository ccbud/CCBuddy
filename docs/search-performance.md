# Local search: file catalog and background tgrep

CC Buddy no longer creates or queries its own SQLite conversation database. The
old schema, FTS, SQL migrations, WAL maintenance and vacuum implementation have
been removed. Conversation metadata and searchable text use `conversation-catalog-v1`.
Original agent transcripts and annotation sidecars remain authoritative.

This does **not** remove read-only compatibility with agent-owned SQLite formats
(Antigravity conversations and Codex state), or change Bifrost's unrelated gateway
storage. Those files are not the conversation search index and are not deleted.
Unused old conversation caches are shown separately in Settings, not silently
counted as new storage or erased during startup.

## Search without waiting for index preparation

1. Read the current file-catalog snapshot and apply source/scope/trash filters.
2. Use an already prepared tgrep handle to select candidate blocks. If none is
   ready, immediately search compressed blocks directly; never open, restore or
   build tgrep on the foreground query path.
3. Verify the **complete query** with Unicode-equivalent literal matching. Publish
   the first usable snippet and message anchor before completing occurrence counts.
4. A separate utility worker restores or updates tgrep. Its previous immutable
   handle stays queryable while new postings are prepared. Changed/uncovered
   documents are always searched directly, so an old checkpoint cannot hide them.

Prepared candidates have a narrow first-result path: read that candidate's header,
validate its configured scope, visibility, owner and exact source/dependency
revision, then publish its verified hit. This does not first enumerate metadata or
validate every unrelated source in the library. Standalone Codex children wait for
complete parent ownership resolution. Full authorized-source discovery follows;
known pack hits are verified before dirty-source work. Progressive snapshots can
insert/reorder stable hit identities while preserving their anchors and monotonic
counts; the final result uses canonical activity order. If discovery disproves a
fast proof, its old anchor is explicitly retired before raw verification. A newly
resolved canonical alias or top-result limit can also retire a provisional snapshot.
Search covers the complete authorized canonical set, not only the library's 5,000
visible rows; the 200-hit result cap is not a source-scan range cap.

Catalog coverage is not the same as source coverage. Query workers additionally
discover authorized source files and compare source/dependency fingerprints. A
quick metadata row, a source absent from the catalog, or a source changed during
the scanner's reparse spacing is verified from the producer file; its old body
packs do not contribute duplicate counts. This path does not wait for a full
catalog parse or tgrep preparation. Every verified hit carries scoped owner metadata
so the search palette can show and open it even outside the visible library window.
If an ordinary JSONL source cannot be identified from the scanner's 256 KiB
preview, the query worker reads its first complete decoded record and stops the
metadata sample there. This covers a first conversation record larger than the
preview without materializing the whole transcript; it does not change the
scanner's startup preview budget or authorize reads outside configured roots.

Source-revision fingerprints and persisted body-coverage proofs are distinct.
For Codex, the body proof excludes the shared annotation sidecar, while retaining
primary-file identity and all body/ownership dependencies. A sidecar-only refresh
can reuse a proven pack only when owner, scope and trash state remain compatible;
its refreshed dependencies are still validated before query completion. Metadata
publication preserves the proof belonging to the actual retained pack in the
atomic catalog snapshot, including concurrent replacement. An unchanged legacy
source revision does not require a startup reparse; when metadata changes and a
legacy row has no body proof, verification conservatively reads the source.

For ordinary Codex and Claude JSONL, verification decodes one record at a time,
uses the same normalized message/block text as the full parser, and retains a
query-sized rolling window with complete-grapheme overlap. This includes JSON
escapes and matches crossing blocks or messages. Memory is bounded by the largest
individual decoded JSON record plus the window, not a fixed bound for arbitrary
single-record inputs. Other adapters retain their existing permission-aware full
parser on the query worker; they are not claimed to have streaming memory bounds.
Source rewrites/cancellation invalidate a search attempt independently of catalog
generation, and a retry retires the old progressive prefix. Continuously changing
sources may require a retry; uninspected source tails cannot produce instant results.
Retries within one query can reuse immutable catalog entries and primitive block
refinements only while catalog UUID, generation, scope and trash filter are unchanged.
They still rediscover and authorize sources, validate every relevant dependency,
and recompute canonical owners; no final hits or source proofs are cached this way.
This reduces repeated catalog work, not the cost of verifying continuously appended
content. Three invalidated attempts still fail explicitly. Before that terminal
failure the repository retires its last prefix with a fresh empty snapshot, so
already disproved anchors are not left as valid results.
Progressive searches separate first-anchor discovery from complete counting for
both catalog and source hits. Once a source yields its first exact snippet, that
pass closes the source and proceeds to later session identities before counting
the hits. The count pass reopens and revalidates the source; only its primitive
answer is retained between passes, not text or a suspended decoder. This can read
a long prefix twice when its first occurrence is late, and does not promise lower
total scan time. Proving a source has no match still requires reading its tail.
Completed source answers also share the existing 2 MiB bounded in-memory exact
answer cache. Keys include the catalog identity, source path, full dependency
fingerprint and literal-query bytes. Reuse validates source and catalog snapshots
again; cancellation never caches a negative answer or a partial count. This avoids
rescanning an unchanged pending source for repeated queries, but does not remove
the first-read cost of a different literal or newly appended text.

The UI distinguishes normal direct search during preparation from an actual
accelerator failure. Query completion does not leave a spinner pretending a
query is still running. Query replacement and session switching cancel obsolete
work; stale generations and replaced catalog identities cannot publish old hits.

There is no artificial per-message 32 KiB or per-tool-output 16 KiB cutoff:
long message, thinking, tool and raw-text tails remain searchable. The searchable
projection follows normalized parser text, excludes metadata-only messages and
injected transport markup, and is not a raw-byte search of binary attachments.
In-session find follows the reader's normalized visible text. Exact lexical
matching does not depend on semantic inference or ANE availability.

Global hits retain their parser-stable source message sequence. When a paired
tool result is rendered inside a different tool-use card, reader navigation maps
that source position to the actual visible owner by tool ID. Mixed messages and
multiple owners are resolved from the matching normalized block on a cancellable
worker, not by guessing a neighboring row. Orphan results stay independent;
overwritten duplicate results are not redirected to unrelated rendered content.

## Storage and correctness

An atomic, checksummed `manifest.json` references immutable `.header` metadata and
`.pack` body objects. The manifest carries a catalog UUID, semantic generation and
monotonically allocated document/block IDs. Headers contain chunk descriptors and
message spans, not a duplicate full transcript JSON string.

Body blocks target 32 KiB UTF-8 and split at complete `Character` boundaries. An
indivisible larger grapheme is the exception. Each block is independently LZFSE
compressed, or stored raw if compression would grow it, with a SHA-256 checksum.
Compression/pack writing occurs outside publication locks. Readers open immutable
packs under a short shared lock and retain their file descriptor through decoding;
garbage collection cannot invalidate an already opened reader by unlinking its pack.

Metadata-only updates also encode and flush replacement headers outside the
publication lock. A short commit compares the catalog identity and each affected
object's name/checksum, then atomically publishes the complete batch against the
current manifest. Conflicts retry with the latest body references; unrelated
session updates do not invalidate prepared headers. Lifetime-leased partial files
survive concurrent collection. Document IDs, content tokens and body packs remain
unchanged for metadata-only edits.

New immutable references and the root manifest publish atomically under an
exclusive lock. Private directories/files use 0700/0600, directory-relative
no-follow I/O, and owner/type checks. Corrupt individual records are skipped and
reparsed from original sources without hiding unaffected sessions. An invalid or
future root manifest fails safely instead of being overwritten with an empty one.
Deferred garbage collection uses small cooperative batches. Abandoned partial
objects require validated identities and an unlocked lifetime lease; unknown
files, symlinks and live writers are preserved.

Eight adjacent blocks share one tgrep posting identity (about 256 KiB) to reduce
posting duplication, while exact verification stays block-sized. Groups include
right lookahead; only a normalized, scalar-aligned query seed is bounded, never
the final literal query. Verification carries nonoverlapping-match progress across
blocks and counts each occurrence only in the block owning its start. UTF-16
offsets map hits to the original normalized message sequence.

The embedded `tgrep-core` 1.0.4 revision is
`e2007b52d2b8fe4176159d0da20c9ba4a46d5aab`, matching the supplied checkout.
Users do not install a CLI or Rust. Native releases embed arm64 and x86_64 bridge
slices. Persistent checkpoints use validated immutable files, atomic publication,
and a publisher lease; relinquishing that lease does not discard the old reader's
mmap. Checkpoints contain trigram postings and numeric IDs, not full transcript
copies. Metadata and compressed packs still contain private information: this is
not encryption, and local catalogs must not be uploaded as test artifacts.

## Real-history measurement contract

Old SQLite measurements are preserved in the explicitly
[historical engineering record](search-performance-history.md). They are not
measurements of this architecture. New measurements must separately report:

- Initial source parsing/catalog construction and background index preparation.
- First verified result and completed counts for `系统代理`, `当前版本` and broad terms.
- Process restart/checkpoint validation versus prepared and repeated-query times.
- Complete file-catalog plus tgrep bytes, counting hard-linked files only once.
- Source integrity, full-count/anchor parity, and large-session interaction checks.

Local benchmarks use authorized real histories, retain only an isolated derived
catalog under ignored `native/build`, and emit aggregate metrics/public test terms.
No private paths, session titles, IDs, queries extracted from conversations or
snippets belong in published evidence. Filesystem caches are not flushed. Peak RSS
is a process-lifetime high-water mark, not per-query allocation or current RSS.
Repository publication timings do not measure UI first paint or frame rate.
Progressive benchmark validation is per source/catalog snapshot attempt: a real
rewrite or canonical reconciliation may retire an earlier snapshot. Initial verified
delivery and the final attempt's first hit are reported separately, both elapsed
from the original query start. Retirement counts are reported, not interpreted as
a monotonic-prefix failure or all mislabeled source rewrites. The post-timing
final-only API comparison may reuse the exact-answer cache and is not an independent
text oracle. Independent Foundation sampling covers at most three small catalog
documents with separately current source-revision proofs; the number of remaining
unverified hits is explicit. Query-local owner metadata alone does not distinguish
a raw answer from a hot pack. Separate live
source snapshots can also invalidate the post-timing API comparison; such a run
fails validation instead of silently claiming parity. The benchmark emits those
differences per query and continues collecting later measurement phases, then
exits nonzero if any comparison failed. A production query execution failure is
reported separately. Typed source-revision invalidation failures are also retained
while later phases continue, ending with nonzero exit status; other execution and
progressive-invariant failures stop immediately. Completed measurements do not
imply successful validation.

### Authoritative-source verification (2026-09-10)

`bash native/Scripts/benchmark-real-history.sh --source-search` read the largest
ordinary Codex/Claude JSONL in the configured local roots: a 458,822,422-byte Codex
session. No catalog was opened and no tgrep handle was prepared. Only bounded
quick metadata was read before timing; filesystem caches were not flushed.

| Public literal | First verified callback | Complete count | Occurrences |
| --- | ---: | ---: | ---: |
| 系统代理 | 3,755.02 ms | 5,011.29 ms | 7 |
| 当前版本 | 46.29 ms | 4,910.77 ms | 18 |

The streaming phase reached a process peak RSS of 70,041,600 bytes (66.8 MiB).
Both source fingerprints stayed unchanged. A subsequent complete production
parser projection plus independent whole-text Foundation matching verified exact
counts, snippets and message anchors for both queries. That separate oracle took
23,525.56 ms and raised process-lifetime peak RSS to 1,171,996,672 bytes; its parsing
and verification are outside the query timings above.

These measurements establish source coverage and bounded-record behavior, not an
instantaneous cold search claim: a first occurrence late in a 458 MB source still
requires reading its preceding records. They are not prepared-tgrep or UI paint
measurements. This was the single full-count streaming API with an early callback,
not a measurement of the repository's subsequent separate first-hit/count passes.
Retained benchmark catalogs now use a stable private
`benchmark-app/imports` sibling for scan/reopen dependency identities; old catalogs
created with disposable scratch imports require a new isolated scan before being
used as a valid-manifest hot-search baseline. Catalog-only sample oracles require
a separately current source-revision proof rather than comparing against stale
body packs or inferring provenance from query-local owner metadata.

### Live-source hot-first verification (2026-09-10)

The clean-child-proof implementation was measured in a fresh process against
the retained catalog while local agents continued writing. Checkpoint restore and
validation took 1,432.49 ms before any query/list. There were 340 canonical visible
sessions and 5,518 posting groups. The timings below include production source
coverage discovery and raw verification of changed or uncovered sources:

| Public literal | Initial verified hit | Final-attempt first hit | Complete search | Hits / occurrences |
| --- | ---: | ---: | ---: | ---: |
| 系统代理 | 20.04 ms | 2,209.91 ms | 5,224.45 ms | 13 / 544 |
| 当前版本 | 141.31 ms | 141.31 ms | 3,813.87 ms | 49 / 781 |

The first query retired one snapshot; the second did not. Both agreed with the
subsequent final-only API, which may reuse exact-answer caches. Independent small
catalog document samples covered zero and one hits respectively, not every result.
The second query's final attempt spent 1,189.46 ms on source coverage and
1,572.88 ms verifying six source candidates totaling 141,181,976 bytes. Process
peak RSS through these two queries was 223,936,512 bytes; current RSS after the
second query was 223,264,768 bytes. These query-process measurements do not prove
that combined fresh-scan/index-preparation memory is fixed.

The same run's broad `error` query delivered its initial verified hit in 123.26 ms
and completed progressive delivery in 13,741.53 ms across four snapshot epochs.
Its subsequent separate final-only comparison differed and the benchmark exited
with `progressiveParity`; the final three-query run is **not a complete parity
pass**. Active source writers can make separate snapshots differ, but this run did
not classify that mismatch and must not be presented as proven source-only drift.
The overall first hit can belong to a smaller session; it is not by itself
evidence of the 458 MB target's own arrival time. These are repository callbacks,
not UI paint measurements or an idle-machine/cold-disk guarantee.

A subsequent target-aware restored run measured the same 458,822,422-byte source's
own `系统代理` hit at 124.82 ms, with seven final occurrences. The overall first
hit was 18.10 ms and the complete progressive call took 4,963.84 ms. Its separate
final-only comparison had identical ordered identities, counts, snippets and
anchors (13 hits / 553 occurrences), but different query-local owner metadata;
full `HistorySearchHit` parity was explicitly false. This establishes a prepared
target arrival measurement, not a metadata-parity pass. A following attempt failed
inside repository execution before all three queries were measured; at that point
the emitted production error type alone did not identify its enum case. Neither
attempt establishes a stable successful three-term suite under active writers.

## Local file-catalog results (2026-09-09)

The following measurements used an Apple Silicon Mac (`Mac16,10`, macOS 26.6.2)
and an isolated, owner-authorized catalog: 1,426 sessions, 1,454 search documents,
37,851 blocks and 1,214,346,762 decoded bytes. An independent full-pack reader and
complete-string oracle found zero differences in candidates, occurrence counts,
first UTF-16 offsets, message anchors and snippets for both public Chinese terms.
These are measurements of this snapshot, not a controlled comparison with the
historical SQLite corpus. Private data and diagnostic artifacts remain local.

The source scan covered 7.276 GB and took 218.56 s (first metadata at 4.85 s).
One 2,616-byte, six-record custom-root file had no recognizable chat/session
records and was independently confirmed unsupported. The source scan's peak RSS
was 1.71 GB. The largest supported source was 458,822,422 bytes. Full-text oracle
totals were 705 occurrences in 30 documents for `系统代理`, and 1,185 occurrences
in 186 documents for `当前版本`; canonical filtering explains the smaller result
counts in the repository table below.

### Cold entry and background preparation

With no prepared in-process tgrep reader, the first cold-entry `系统代理` query
published a verified result in 121.57 ms using direct search; complete counts
took 10.455 s. Subsequent prepared queries delivered first results around 25–38 ms,
but broad `error` searches still took 5.8–6.5 s to finish counts for the 200-session
limit. Neither a fast first result nor a prepared-query measurement establishes
instant completion for every fragment or a cold-disk guarantee.

A separate no-checkpoint build-only profile of an APFS-cloned catalog prepared
5,485 tgrep groups in 47.007 s with sampling enabled and peak RSS 966,246,400 bytes.
The earlier combined scan/index/query process reached 4.55 GB peak RSS. The
separate build-only profile did not reproduce or fully attribute that peak; the
new autorelease-pool boundaries are not evidence that it has been fixed.

### Restored progressive repository search

A fresh benchmark process restored and validated the existing checkpoint in
1,558.03 ms before any query/list warm-up. Its production canonical repository
contained 340 visible sessions; it was not an unrestricted result list of all
1,426 catalog entries. The first query of each term, excluding explicit repeats:

| Query | First verified snippet/anchor | Complete repository search | Returned hits | Exact occurrences |
| --- | ---: | ---: | ---: | ---: |
| `系统代理` | 29.24 ms | 766.74 ms | 13 | 298 |
| `当前版本` | 25.68 ms | 781.05 ms | 49 | 599 |

Both searches used tgrep, preserved progressive result identity/snippets/anchors,
and agreed with the final-only repository API. Process-lifetime peak RSS was
101,531,648 bytes across the entire query sequence. These are delivery callbacks,
not UI paint or interaction measurements. The run was **not an idle-machine
baseline**: a preview app was observed at approximately 114% CPU when querying
started and was subsequently quit. OS filesystem caches were not flushed;
checkpoint preparation and scope/list resolution prewarmed metadata, and the
second term also followed the first term's out-of-timing oracle reads. No producer
scan was started; repository metadata discovery may still perform metadata reads.

### Metadata-update contention

An independent optimized-build probe selected the session with both the largest
active header (2,674,162 bytes) and largest searchable document (61,668,810 decoded
bytes, 1,882 blocks). Each mode ran 20 rounds, simultaneously releasing one
metadata writer plus generation, full-list and one-window readers. The writer
republished the same metadata values with a new derived revision. No tgrep worker
or producer loader was started. Both instances, metadata and the bounded window
were explicitly prewarmed; 20 no-write read controls preceded each mode.

The same corpus and probe were run before and after lock-external header
preparation plus per-object compare-and-swap (CAS) publication:

| API P95, ms | Same instance, before | Same instance, after | Two instances, before | Two instances, after |
| --- | ---: | ---: | ---: | ---: |
| Generation | 61.80 | 0.12 | 78.10 | 39.70 |
| Full metadata list | 68.42 | 9.57 | 119.61 | 53.09 |
| One bounded search window | 62.26 | 3.27 | 112.62 | 42.45 |
| Metadata writer | 47.12 | 52.09 | 98.29 | 70.58 |

These are end-to-end API latencies, not instrumented pure lock-wait times. Writer
latency includes the new lock-external encoding/I/O. The remaining two-instance
list P95 was 53.09 ms (maximum 53.30 ms): a changed header still requires its first
decode under the reader's lock. This result does not establish a universal
sub-50-ms guarantee. Percentiles use nearest rank over 20 samples per operation;
normal host scheduling was not isolated or CPU-pinned. Every round checked exact
generation advancement, list metadata and window content/spans. All 80 writes
across the two runs passed; catalog identity and every body pack's inode, size and
modification time remained unchanged.

### Garbage collection: include the pre-cleanup cost

The two contention runs deliberately retained old immutable headers. Before
collection, the test catalog contained approximately **214 MB from the 80 metadata
republications**, plus superseded quick-metadata headers. The exact measured
unreferenced total was 216,335,774 bytes; it is not omitted from storage reporting.

| Private catalog metric | Before collection | After collection |
| --- | ---: | ---: |
| All regular-file logical bytes, including tgrep | 1,248,303,615 | 1,031,967,841 |
| Device/inode-deduplicated bytes, including tgrep | 1,248,303,615 | 1,031,967,841 |
| Header files | 2,932 | 1,426 |
| Body pack files | 1,426 | 1,426 |
| Eligible unreferenced files | 1,506 | 0 |
| Eligible unreferenced bytes | 216,335,774 | 0 |

All 1,506 removed objects were unreferenced headers. Reachable objects remained
436,640,226 bytes: 54,678,397 bytes of headers and 381,961,829 bytes of compressed
packs. One explicit `finishFullScanMaintenance` pass completed in 88.04 ms and
left no pending work. This timing followed a full integrity warm-up and excludes
the before/after audits. It includes reference collection and directory
enumeration: the implementation's 250-ms cooperative loop budget is not a hard
deadline for the whole maintenance call. A fresh catalog instance's initial
`pending` flag is false, so the verifier always invoked a first pass before
checking whether further passes were needed.

Before and after collection, the verifier checked every reachable header checksum,
every stored block checksum and decoded UTF-16 length, and complete pack hashes.
Manifest bytes, identity, generation, metadata, document/block counts, reachable
file identities and contents all matched. The two audits each covered the full
1,214,346,762 decoded bytes. tgrep and all other non-GC files were unchanged, and
no original producer history was opened or modified. Byte totals are `stat` file
lengths with and without hard-link deduplication, not APFS clone-exclusive storage
or a claim about newly available whole-volume space.

### Native tests and app-level checks

The `315462b` hosted run executed **992/992 distinct native tests**, including
**11/11 installed-CLI/Bifrost E2Es**, with zero skips or expected failures. Its
downloaded result artifacts separately report **25/27 UI tests passed**: the
paired-output owner's accessibility visibility and the 12,000-message search-field
query still failed. Packaging after that failed gate did not run. Earlier builds,
manual checks and local compilation are not substitutes for exact-head CI.

The subsequent `42c59c8` artifacts contain **1,044/1,044 distinct native tests**,
including the same **11/11 installed-CLI/Bifrost E2Es**, with zero skips. Its UI
result was **24/27**, not a pass: the paired-result mouse click missed the drawn
button, the visible 12,000-message tail failed accessibility hit testing, and a
display-wide window did not resize from a point inside its client edge. The next
revision unifies real view geometry and exposes the resize band using a normal
window move; complete exact-head CI remains required.

The `069f4c8` artifacts contain **1,048/1,048 distinct native tests**, including
**11/11 installed-CLI/Bifrost E2Es**, with zero skips or expected failures. All
**28 UI methods** were discovered, with **26 passed**. Paired-result clicking and
compact resizing passed; tail accessibility hit testing and the slow-count test's
initial observation window still failed. Packaging after that failed gate did not
run. Local successful Release checks for that revision are separate evidence.

The `1a1e53f` artifacts contain **1,051/1,051 distinct native tests**, including
**11/11 installed-CLI/Bifrost E2Es**, and **27/28 UI tests passed**, with zero skips
or expected failures. The slow-count regression passed. The remaining 12,000-message
failure recorded a 14.233-second whole-app existence query returning false before
hittability was evaluated, while the CI recording showed the complete tail visible.
The next regression lookup uses the real table/row/cell/host hierarchy and retains
the same timeouts, exact host identifier, hittability and prepared-text assertions;
this does not claim constant-time XCTest snapshots. Complete exact-head CI is still
required, and packaging did not run after that failed gate.

The reader now owns an `NSScrollView`/`NSTableView` boundary. Only available rows
host message content; logical offscreen accessibility rows retain source identities
without loading text from accessibility getters. Real row/cell/hosting objects
share consistent modern and legacy public accessibility routing. No substitute
message or Result controls are used. A constant-time presentation-input boundary
prevents unrelated Store updates from rebuilding the transcript. Cached heights
and source-row/pixel anchors preserve reading position through append and reflow;
manual input revokes pending navigation. Disclosure choices survive row reuse
without keeping offscreen transcript strings alive.
Message identifiers belong to their real visible hosting views. These hosts and
the actual Result button derive modern/legacy accessibility frames and activation
points from the same live view bounds, including clipping after a scroll.
Public accessibility hit testing follows the actual rendered NSView hit into the
same row/cell/host ancestry, preserving native controls and SwiftUI's own semantic
descendants. This avoids the default table resolver stopping at an outer cell
while the identified message host is visible. Clipped/offscreen content is not
made hittable, and querying a hit does not materialize offscreen logical rows.
Paged row lookup computes the visible range once and only asks for already-rendered
native rows in that range; all requested offscreen logical rows remain available.
Actual mounted-row or logical-topology changes coalesce accessibility layout
notifications. Unchanged layout does not repeatedly notify or move focus.

Search palette and sidebar rows carry explicit metadata/hit/query/selection/language
snapshots as their lazy-list inputs. Stable file identity is retained while counts,
snippets and accessibility values update. Each mounted row also observes current
Store refinements directly, independent of its surrounding lazy reader closures.
This addresses real-history rows retaining
their first lower bound until the palette was reopened. A three-source slow-count
UI regression requires observed initial, intermediate and final values without
reopening or scrolling the palette; real-history checks cover the original case.

One responsive toolbar layout keeps a single native search editor through width
changes instead of constructing two interactive fields in `ViewThatFits`. Local
production-reader interaction verified all 12,000 messages, both Chinese query
replacements, exact `1/1` counts, the actual message 11,999 and its complete prepared
tail, Focus enter/exit, and return to a two-message session with an empty detail
query. The paired-output fixture exposed the actual visible owner 1,200 and no
independent hidden-result row 1,201. Expanding its real tool result exposed all
179,258 characters exactly. Scrolling away, changing reader width, and returning
retained the expansion without reclaiming the old search anchor.

Those checks also caught a missing tool-button accessibility label and vertical
wheel events consumed by horizontal-only tool output. The visible disclosure strip
now uses one real `NSButton` for drawing, keyboard/mouse activation and accessibility;
its localized title, byte summary and collapsed/expanded state were verified through
external accessibility and actual clicks. Vertical events over horizontal-only
output reach the outer reader with native phases/momentum, while horizontal gestures
remain local. The full-output, scroll-away, width-change and retained-disclosure
checks were repeated successfully with this control.

Local XCTest/IDE handshakes have failed before business cases started; these
failures are not native test passes. A predecessor standalone diagnostic executed the 31 native
reader/button test method bodies with their assertions; that is not an XCTest run.
Exact-head CI requires at least 1,054 native cases and all 28 UI cases, including six
actual text-selection/copy operations, live following, replacement/cancellation,
large-message tails and light/dark/compact presentation. The CI artifacts and PR
record the executed final revision; this document does not substitute for them.

Both the offscreen logical rows and rendered native rows publish AppKit's standard
`AXRow` / `AXTableRow` classification through the modern and legacy accessibility
interfaces. A real `NSTableView` comparison checks all 12,001 row classifications,
visible and offscreen ancestry, and that this inspection realizes no extra views.
Failed long-tail UI assertions record a bounded public hierarchy diagnostic only
after the original predicate budget has expired; passing criteria are unchanged.

An earlier isolated Release preview opened the **458,822,422-byte, 16,921-message**
real session at source sequence 12,192 on visible tool-use owner 12,191. Detail
search returned `1/2 · 7` for `系统代理` and `1/16 · 18` for `当前版本`. This is
predecessor-reader evidence, not validation of the final native-table Release.
Only public aggregate measurements are recorded; original histories and real UI
captures remain local.

## Running the benchmark

```sh
bash native/Scripts/benchmark-real-history.sh --compile-only
bash native/Scripts/benchmark-real-history.sh --inventory
bash native/Scripts/benchmark-real-history.sh --largest
bash native/Scripts/benchmark-real-history.sh --detail
```

`--inventory`, `--largest` and `--detail` do not create/open a conversation catalog.
For a real scan, create a private parent with `mktemp -d` directly under
`native/build/ccbuddy-query-benchmark.XXXXXX`, and pass its absolute path with
`/catalog` appended:

```sh
bash native/Scripts/benchmark-real-history.sh --run \
  --catalog /absolute/private/benchmark-parent/catalog \
  --prepare-index --progressive-repository --require-known-hits
bash native/Scripts/benchmark-real-history.sh --restore --prepare-index \
  --catalog /absolute/private/benchmark-parent/catalog \
  --progressive-repository --require-known-hits
```

The placeholder must be replaced with the validated private directory described
above. Catalog modes reject live app locations, symlinks and nonprivate parents.
Only `--run` scans producers. `--queries` reuses a catalog without rescanning;
`--restore` measures preparation in a fresh process before any query/list prewarm.
The production repository may start background preparation after the cold entry
query begins, so waiting for it later is reported as *remaining* preparation time,
not the full build cost. Each row reports its actual engine and cache conditions.
`--fallback-repository` explicitly disables tgrep in the isolated benchmark.
`--migrate`, `--baseline-fts` and private-path `--show-roots` are retired.

## Regression checks

The native suites exercise atomic replacement, concurrent initialization and
publication, failed initialization FD ownership, corrupt blocks/manifests, future
format refusal, interrupted-object recovery, Unicode/block/group boundaries,
same-generation catalog replacement, cancellation, live updates, low-space
recovery, and exact snippet/count/anchor parity. UI tests cover large result sets,
12,000-message navigation, long single-message tails, search replacement, keyboard
focus, hidden paired-result owner navigation, unavailable acceleration, live
following and light/dark/compact layouts.

```sh
cargo test --locked --manifest-path native/TgrepBridge/Cargo.toml
CCBUD_TGREP_ARCH=universal bash native/Scripts/build-tgrep.sh
xcodegen generate --spec native/project.yml --project native
```

The PR pipeline requires all native tests (including installed-CLI/Bifrost E2Es),
UI tests and unsigned universal packaged self-checks, with no skipped native/UI
cases. A previous commit's green CI is not evidence for a changed PR head.
