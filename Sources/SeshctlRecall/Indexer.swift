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
    private let embedder: any Embedder
    private let adapters: [any Adapter]

    public init(
        store: VectorStore,
        embedder: any Embedder,
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
    /// 3. Filter out entries already in the DB from a prior canceled
    ///    refresh (resumability — see `VectorStore.filterAlreadyIndexed`).
    /// 4. For each chunk of `batchSize` entries:
    ///    a. Check cancellation.
    ///    b. Embed the chunk's texts via `EmbeddingService`.
    ///    c. Insert (chunk entries, embeddings) into the store.
    ///    d. Fire the progress callback.
    /// 5. Persist the new cursor — only after ALL chunks for the adapter
    ///    succeed, so a cancellation mid-adapter leaves the cursor stale
    ///    and the resumed refresh re-walks (cheap) and re-filters (skips
    ///    already-persisted via the composite UNIQUE constraint).
    ///
    /// Drift check runs first: if entry/embedding counts disagree, wipe
    /// everything (including cursors) and re-walk from the beginning.
    ///
    /// Progress: `onProgress(done, total)` fires once after the filter
    /// step (to credit already-persisted entries from a prior canceled
    /// run) and once per chunk thereafter. `total` is the cumulative
    /// count of entries seen across adapters so far. The final call
    /// satisfies `done == total` unless cancellation fired.
    public func refresh(
        batchSize: Int = 64,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws {
        if try await store.detectDrift() {
            // Stderr log is the temporary surface; routing to
            // ~/Library/Logs/Seshctl/install.log via appendInstallLog is a
            // known follow-up.
            FileHandle.standardError.write(Data(
                "[recall] drift detected (entries vs embeddings count mismatch); clearing index\n".utf8
            ))
            try await store.clearAllEntriesAndEmbeddings()
        }

        var done = 0
        var total = 0

        for adapter in adapters {
            try Task.checkCancellation()
            let cursor = try await store.readCursor(adapterName: adapter.name)
            let (allNewEntries, newCursor) = try await adapter.load(cursor: cursor)
            guard !allNewEntries.isEmpty else {
                // Even with zero new entries, advance the cursor so future
                // refreshes don't re-walk the same files.
                try await store.writeCursor(adapterName: adapter.name, cursor: newCursor)
                continue
            }

            // Resumability: filter out entries already in the DB from a
            // prior canceled refresh. The composite UNIQUE
            // (text_hash, agent, session_id) makes this load-bearing —
            // without the filter we'd re-embed entries we already paid
            // CoreML cost for, just for the INSERT OR IGNORE to drop them.
            let toEmbed = try await store.filterAlreadyIndexed(allNewEntries)
            let alreadyDone = allNewEntries.count - toEmbed.count

            total += allNewEntries.count
            done += alreadyDone
            // Credit already-persisted work to progress immediately so the
            // user sees the "we resumed from N/total" state up front.
            onProgress?(done, total)

            let chunkSize = max(1, batchSize)
            var chunkStart = 0
            while chunkStart < toEmbed.count {
                // Worst-case cancellation latency: one chunk's embed time
                // (~50ms × chunkSize CoreML predictions ≈ 3s for the
                // default batchSize=64). CoreML.prediction is synchronous
                // so the in-flight chunk can't be interrupted partway.
                try Task.checkCancellation()
                let chunkEnd = min(chunkStart + chunkSize, toEmbed.count)
                let chunk = Array(toEmbed[chunkStart..<chunkEnd])
                let chunkEmbeddings = try await embedder.encode(
                    chunk.map(\.text),
                    batchSize: chunk.count,
                    onProgress: nil
                )
                precondition(
                    chunkEmbeddings.count == chunk.count,
                    "Indexer: embedder returned \(chunkEmbeddings.count) vectors for \(chunk.count) inputs"
                )
                try await store.insert(entries: chunk, embeddings: chunkEmbeddings)
                done += chunk.count
                onProgress?(done, total)
                chunkStart = chunkEnd
            }

            // Cursor only after ALL of this adapter's entries are persisted.
            // A cancellation mid-loop above leaves the cursor stale; the
            // resumed refresh re-walks (cheap) and filterAlreadyIndexed
            // skips what we already wrote.
            try Task.checkCancellation()
            try await store.writeCursor(adapterName: adapter.name, cursor: newCursor)
        }
    }
}
