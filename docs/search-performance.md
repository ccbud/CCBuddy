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

The last executed local native/unit run passed **892 tests with zero skips**,
including all 11 installed-CLI/Bifrost end-to-end cases. Hosted CI subsequently
passed **902 native tests**, including the ten visible-tool-owner navigation
regressions. Its UI run passed 24/26: the long-message test did not clear its global
filter before switching sessions, and the tool-result test used a localized
disclosure value that did not match its English runtime. Both test interactions
have been corrected without removing their assertions.

The reader changes add ten source-scoped layout-intent, resident-input and Store
cancellation regressions. Local app and test bundles compile, but local
XCTest/IDE control-session handshakes have failed before any business test starts;
these are not 912-test passes. Local UI XCTest also did not initialize.
CI now requires at least 919 native tests and all 27 UI cases for the exact
PR head. Manual checks and an earlier commit's build are not substitutes for that
requirement.

A full-app stress fixture exposed a separate SwiftUI lazy-stack layout hang when
expanding a 179,258-character paired tool output near message 1,200, following
twenty alternating multi-paragraph Markdown/tool rows. The reader now uses one
native-backed virtualized `List`, retaining the complete transcript and stable
message anchors. Source-scoped layout correction is revoked synchronously on
manual navigation; one resident input observer remains available even when the
old target row has been recycled or a search has no target yet. Text selection
stays local to content rather than inherited across the whole reader.

The minimal List implementation opened and expanded the full output in actual
local app interaction: its only fragment remained at UTF-16 offset 179,208,
and the complete 179,258-character accessible output matched the fixture. The
action plus accessibility roundtrip took about 1.6 s; this is not a frame-paint
measurement. A subsequent process sample showed 0.4% CPU instead of the sustained
layout loop. Wheel scrolling and hiding the session list caused real Markdown
reflow without pulling the reader back to the old hit. Actual double-click
selection also selected the exact expected text in tool notes, all three todo
states and both diff sides. A new UI regression separately requires six native
double-click/Cmd-C operations, exact clipboard contents and restoration of the
original clipboard. Accessibility checks and final Release/hosted-CI verification
remain required.

The `2bba76b` hosted run passed all 912 native tests, including 11 installed-CLI
E2Es, and 25 of 27 UI tests. Native selection/copy passed. The two failures were
the initial paired-output owner's accessibility visibility and reading back the
search field in the 12,000-message case; neither is treated as a pass. Packaging
steps after the failed UI gate did not run.

The follow-up isolates the reader behind a constant-time presentation-input
equality boundary and reuses each row's existing `ForEach` identity. Unrelated
Store and search-field focus changes no longer rebuild the entire reader. Seven
new unit regressions cover content revision, source, query, font and navigation
invalidation. An isolated Debug check of the 16,921-message source completed global
`系统代理` in 871.3 ms, preserved both detail-query counts below, and accepted
three real PageUp events that revoked the old search anchor. These timings are
not a Release comparison. The paired-owner external accessibility issue remains
unresolved in this check; a successful build or lower idle CPU does not fix it.

In the current Release app, a live conversation advanced from 3,710 to 3,723
messages while showing approximately 6.4 million tokens. In-session searches for
both Chinese terms and focus restoration were verified. For global `系统代理`,
the app's diagnostics recorded 192.5 ms to the first result and 1,303.2 ms to
completion. These are diagnostic search times, not frame-paint measurements; the
run overlapped compilation and background producer updates. This live-session
check is separate from the largest-session check below.

In a subsequent isolated Release preview, the **458,822,422-byte, 16,921-message**
real session opened the global `系统代理` hit at source sequence 12,192 on its
visible tool-use owner, 12,191. The owner remained visible after asynchronous
neighbor layout settled. This query completed in 935.7 ms on the 340-session UI
profile; it is not the 1,426-session benchmark corpus. In-session searches returned
`1/2 · 7` for `系统代理` and `1/16 · 18` for `当前版本`. Only public aggregate
measurements are recorded here; original histories and UI captures remain local.

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
