# Offline semantic search and Apple Neural Engine

The search palette optionally reranks retrieved conversations by meaning with a
bundled MiniLM-L6-v2 Core ML model. tgrep/SQLite supplies the authorized keyword
candidates first. Semantic ranking examines at most 32 candidates and cannot add
conversations outside that set. Turning the option off restores retrieval order.
No model download, API key, server, or Python runtime is needed by the application.

## Model and hardware contract

- Source: `sentence-transformers/all-MiniLM-L6-v2`, Apache-2.0, pinned revision
  `1110a243fdf4706b3f48f1d95db1a4f5529b4d41`.
- 384-dimensional embeddings, 128-token static input, masked mean pooling and
  normalized cosine similarity. The model is English-trained; English and code
  queries are its intended use. Queries containing non-Latin letters retain
  their keyword order. This is a conservative script check, not language detection.
- 22,594,048 bytes of quantized weights. Linear layers are replaced by equivalent
  1×1 convolutions; attention stays four-dimensional for ANE-friendly scheduling.
  Int8 weight storage is decoded for float16 model computation. This is **not** a
  claim that every operation executes in int8 on the Neural Engine.
- Apple Silicon: Core ML `.cpuAndNeuralEngine`. Intel: `.cpuOnly`. If ANE model
  loading fails, loading is retried on CPU. Other model errors retain keyword
  results and expose an unavailable state. macOS 13 remains supported.
- On macOS 14.4+, `MLComputePlan` reports anticipated placement. The interface
  distinguishes this plan from actual hardware-utilization telemetry. On older
  systems, it reports the configured compute policy and leaves placement unknown.
- Actor isolation keeps prediction off the main actor. Cancellation is checked
  before model preparation, after preparation, and between predictions. A single
  shared preparation task avoids duplicate model compilation. A 512-entry memory
  LRU caches vectors by a SHA-256 of the complete input text. No text or vectors
  are written to an application index or transmitted over the network.

## Recorded validation

Production Swift service, release optimization, Apple M4, macOS 26.6.2
(25G83), 2026-09-07. The same quantized model was run using both compute policies.
The ranking query was “Fix authentication errors when the API key expires.”
“Renew credentials to restore access to the service.” ranked above database and
appearance changes despite having no literal keyword match.

| Measurement | CPU + Neural Engine | CPU only |
| --- | ---: | ---: |
| Planned ANE operations / reported operations | 147 / 155 | 0 / 155 |
| First model preparation + query + 3 candidates | 1,705.9 ms | 356.8 ms |
| Uncached query + 3 cached candidates, median of 10 | 0.774 ms | 1.836 ms |
| Fully cached query + 3 candidates | 0.085 ms | 0.095 ms |

Warm uncached-query reranking was about 2.37× faster with CPU + ANE in this run.
These are observed application-path timings, not throughput guarantees or a
32-uncached-candidate measurement. The one-time specialization cost is included
in the cold measurement; results vary with hardware, OS, thermal state and cache.
The 147-operation figure is Core ML's compute plan, not an Instruments trace.

Four conversion examples achieved cosine similarity of 0.99949–0.99962 against
the original float32 PyTorch model. The convolution rewrite is checked before
conversion with `atol=2e-5, rtol=2e-4`; the final quantized model must exceed 0.995
cosine similarity for every checked example. These fixtures establish numerical
parity, not a multilingual or broad retrieval-quality benchmark.

`LocalSemanticSearchTests` exercises the actual bundled model, CPU parity,
cache invalidation by changed text, unsupported-script behavior, missing-model
fallback, work bounds and cancellation. `SemanticWordPieceTokenizerTests` checks
upstream golden token IDs, Unicode handling and the 128-token limit. Store tests
cover toggling and stale asynchronous results.

## Reproduce

The standard-library verifier requires no conversion dependencies:

```sh
python3 native/Scripts/verify-semantic-model.py
```

To regenerate an equivalent model on macOS, follow the pinned Python/toolchain
commands in `native/Scripts/build-semantic-model.py`. The script verifies SHA-256
checksums of all downloaded inputs, loads only safetensors, checks numerical
parity, and writes a new artifact manifest. Core ML package UUIDs can change
between conversions, so byte-for-byte package reproducibility is not asserted.

To benchmark the exact production service without launching the app:

```sh
xcrun swiftc -O -warnings-as-errors -parse-as-library \
  -target arm64-apple-macos13.0 \
  native/Sources/Services/SemanticWordPieceTokenizer.swift \
  native/Sources/Services/LocalSemanticSearch.swift \
  native/Scripts/semantic-search-benchmark.swift \
  -o /tmp/ccbuddy-semantic-benchmark
/tmp/ccbuddy-semantic-benchmark native/Resources/SemanticSearch
```

Use `x86_64-apple-macos13.0` on Intel. Both benchmark passes select CPU there;
`forceCPU` exists to compare policies on Apple Silicon, not to emulate Intel
hardware performance.
