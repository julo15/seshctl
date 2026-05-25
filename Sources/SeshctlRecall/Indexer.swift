// Indexer — orchestrates per-adapter transcript walks, embedding, and
// persistence.
//
// One `Indexer` instance per process. `refresh()` is the only public entry
// point: it sweeps every registered adapter, embeds the new entries via
// `EmbeddingService`, and commits each adapter's batch (entries + embeddings
// + cursor) before moving to the next.
//
// Drift handling: before doing anything, ask the store whether
// `recall_entries.count != recall_embeddings.count`. If yes, wipe the world
// (entries + embeddings + cursors) and re-index from scratch. Mirrors
// `recall/index.py`'s posture from the Python pipeline.
//
// Concurrency: `actor` so two simultaneous `refresh()` calls serialize
// instead of double-embedding. The adapter loop itself is sequential — the
// dataset is small and embedding is the bottleneck, not the walk.

import Foundation

public actor Indexer {
    private let store: VectorStore
    private let embedder: EmbeddingService
    private let adapters: [any Adapter]

    public init(
        store: VectorStore,
        embedder: EmbeddingService,
        adapters: [any Adapter]
    ) {
        self.store = store
        self.embedder = embedder
        self.adapters = adapters
    }

    /// Bring the index up to date incrementally.
    ///
    /// For each registered adapter, in order:
    /// 1. Read the persisted cursor (or `nil` on first run).
    /// 2. Ask the adapter to walk + emit fresh entries past the cursor.
    /// 3. Embed the texts in `batchSize`-sized chunks via `EmbeddingService`.
    /// 4. Insert (entries, embeddings) into the store. UNIQUE(text_hash)
    ///    drops any duplicates left from re-walks.
    /// 5. Persist the new cursor — only after the insert succeeds, so a
    ///    crash mid-embed re-walks the same range on the next refresh.
    ///
    /// Drift check runs first: if entry/embedding counts disagree, wipe
    /// everything (including cursors) and re-walk from the beginning.
    ///
    /// Progress: `onProgress(done, total)` fires after each adapter's
    /// batch completes. `total` is the cumulative count of entries seen
    /// across adapters so far — it grows as adapters report new batches,
    /// rather than being known up front. The final call always satisfies
    /// `done == total`.
    public func refresh(
        batchSize: Int = 64,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws {
        if try await store.detectDrift() {
            // Stderr log is the temporary surface; Phase 6/8 will wire to
            // ~/Library/Logs/Seshctl/install.log via the existing
            // appendInstallLog helper.
            FileHandle.standardError.write(Data(
                "[recall] drift detected (entries vs embeddings count mismatch); clearing index\n".utf8
            ))
            try await store.clearAllEntriesAndEmbeddings()
        }

        var done = 0
        var total = 0

        for adapter in adapters {
            let cursor = try await store.readCursor(adapterName: adapter.name)
            let (newEntries, newCursor) = try await adapter.load(cursor: cursor)
            guard !newEntries.isEmpty else {
                // Even with zero new entries, advance the cursor so future
                // refreshes don't re-walk the same files. Adapters that
                // produce a stable cursor with no entries (e.g. "scanned
                // everything, nothing new") will land here.
                try await store.writeCursor(adapterName: adapter.name, cursor: newCursor)
                continue
            }

            total += newEntries.count
            // Capture pre-encode `done` so the embedder's per-batch callback
            // can be lifted to the global (cross-adapter) progress space.
            // Without this, the user sees zero progress until ALL of an
            // adapter's entries finish embedding — ~7 minutes for an
            // 8000-row Claude history.
            let baseDone = done
            let totalSnapshot = total
            let embeddings = try await embedder.encode(
                newEntries.map(\.text),
                batchSize: batchSize,
                onProgress: { batchDone, _ in
                    onProgress?(baseDone + batchDone, totalSnapshot)
                }
            )
            precondition(
                embeddings.count == newEntries.count,
                "Indexer: embedder returned \(embeddings.count) vectors for \(newEntries.count) inputs"
            )
            try await store.insert(entries: newEntries, embeddings: embeddings)
            try await store.writeCursor(adapterName: adapter.name, cursor: newCursor)

            done += newEntries.count
            onProgress?(done, total)
        }
    }
}
