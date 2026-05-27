# Native recall (SeshctlRecall) — architecture note

The semantic-search box in Seshctl runs entirely in-app. There is no subprocess, no Python interpreter, no on-demand model download. Everything — tokenization, embedding inference, vector storage, top-K ranking, per-tool transcript scanning — lives inside the `SeshctlRecall` SwiftPM target.

This note covers the parts of that system that matter to a future maintainer.

## Module shape

```
Sources/SeshctlRecall/
├── RecallService.swift           # public facade (search, indexing-state notifications)
├── EmbeddingService.swift        # CoreML model wrapper, actor-isolated
├── TokenizerService.swift        # swift-transformers BertTokenizer wrapper
├── VectorStore.swift             # GRDB-backed embeddings + entries persistence
├── Indexer.swift                 # adapter → embed → persist; chunked + cancellable
├── Search.swift                  # top-K cosine via Accelerate vDSP_dotpr
├── Embedder.swift                # protocol — production = EmbeddingService, tests = MockEmbedder
├── Adapter.swift                 # protocol — per-tool transcript walker
├── AdapterRegistry.swift         # production wiring (claude, codex, gemini)
├── Adapters/{Claude,Codex,Gemini}Adapter.swift
├── HistoryEntry.swift            # internal row type
└── Models/
    ├── all-MiniLM-L6-v2-int8.mlpackage   # ~22MB INT8-quantized CoreML
    ├── tokenizer.json
    └── tokenizer_config.json
```

`SeshctlCore` does not depend on `SeshctlRecall`. The CLI does not depend on either. UI and the app target both import `SeshctlRecall` directly.

## Where the model lives at runtime

The bundled CoreML model + tokenizer have two resolution paths, in this order:

1. `Bundle.main.resourceURL/Models/` — the conventional macOS app-bundle layout. `scripts/build-app-bundle.sh` copies the SwiftPM-generated `Models/` directory here when assembling `Seshctl.app/Contents/Resources/`.
2. `Bundle.module/Models/` — the SwiftPM-generated bundle. Used by `swift test`, `swift run SeshctlApp` from a checkout, and anything else that doesn't go through the .app wrapper.

The two-path lookup lives in `EmbeddingService.resolveBundledResources()`. Tests reach the same resolver via `EmbeddingService.bundledTokenizerFolderURL()` (the test bundle on its own does **not** carry `Models/`).

## How to bump the model

1. Edit `.agents/spikes/2026-05-25-recall-spike/convert-model.py` if the source HF model or quantization config changes. Locked config today: FP32 compute precision, `linear_quantize_weights(mode="linear_symmetric", weight_threshold=512)`, `macOS14` deployment target.
2. Re-run the spike end-to-end (see the spike README). Confirm `compare-topk.py` still shows Top-1 ≥ 19/20 and Top-3 set agreement ≥ 18/20 against the Python reference. If parity slips, stop and re-strategize.
3. Re-capture the tokenizer parity fixture by running the spike's `dump-python-reference.py` (or the trimmed `tokenizers`-only script in the spike directory) and replace `Tests/SeshctlRecallTests/Fixtures/tokenizer-parity.json` with the new captures. The Swift parity test `TokenizerParityTests` then asserts byte-for-byte token-ID identity.
4. Commit the new `Sources/SeshctlRecall/Models/all-MiniLM-L6-v2-int8.mlpackage` (and `tokenizer.json` + `tokenizer_config.json` if either changed).
5. Bump `CFBundleVersion` / `CFBundleShortVersionString` in `Resources/Info.plist` for the release that ships the new model.

## Background indexing — the load-bearing invariants

`RecallStack.indexingTask` (inside `RecallService`) is **detached**. Caller cancellation of `RecallService.search` does NOT stop indexing — the index keeps building so the user's *next* search picks up where the previous one was cancelled.

A `passID` (UInt64, monotonically incrementing) guards against cross-talk between consecutive refreshes. Every indexing `Task` carries its `passID`; every progress event the UI receives is filtered by `passID == currentPass` before it lands in published state. This prevents late-arriving progress events from a stale pass from clobbering a fresher pass's UI.

`lastIndexingProgress` is cached so a search subscriber that arrives mid-indexing immediately sees the current progress (otherwise the UI would briefly look idle until the next batch finishes).

## Resumability

`VectorStore` keeps a composite `UNIQUE (text_hash, agent, session_id)` on `recall_entries`. `Indexer.filterAlreadyIndexed` loads the existing `text_hash` set once per refresh and short-circuits entries that are already persisted. Cancel an in-progress index build, search again, and `Indexer.refresh` only re-embeds the unfinished tail.

The chunked structure of `Indexer.refresh` (64 entries per CoreML batch, written transactionally per batch) means worst-case work lost to a cancel is one batch.

## Sparkle delta cost

The model + tokenizer files are byte-stable across Seshctl releases unless the model itself is bumped. Sparkle's `BinaryDelta` therefore excludes them from the delta payload — steady-state Sparkle deltas for `v0.5.x → v0.5.y` stay small even though the full DMG is ~37MB.

The one-time DMG-size cost is paid by users on the full download (typically the first time they install or every time they upgrade across a model bump). Bandwidth budget allows for this.

## Cross-references

- Phase 1 spike (proves tokenizer + embedding parity): `.agents/spikes/2026-05-25-recall-spike/`
- Implementation plan: `.agents/plans/2026-05-25-0055-native-recall-rewrite.md`
- Adapter test fixtures: `Tests/SeshctlRecallTests/Adapters/`
- Tokenizer parity fixture: `Tests/SeshctlRecallTests/Fixtures/tokenizer-parity.json`
- Adding a new LLM-tool adapter: AGENTS.md → "Adding an LLM Tool" section
