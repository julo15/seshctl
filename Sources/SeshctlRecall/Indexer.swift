// Indexer — orchestrates per-adapter transcript walks, embedding, and
// persistence.
//
// One `Indexer` instance per process. Indexing runs in two phases:
//
// 1. `indexText()` walks every registered adapter and stores new message
//    text. The FTS triggers index each row as it lands, so keyword search
//    sees new messages right away. Cheap: no model involved.
// 2. `embedPending(...)` embeds every stored entry that has no vector yet.
//    Slow (CoreML), and only semantic search needs it.
//
// `refresh(...)` runs both. Keyword search runs only phase 1, so typing in
// the panel never waits on the model.
//
// Entries waiting for an embedding are normal, not corruption: phase 2
// backfills whatever phase 1 (or an interrupted earlier pass) left behind.
//
// Concurrency: `actor`. Two passes that overlap (a keyword search's text
// phase while a semantic refresh runs) are safe: inserts dedup on
// `(text_hash, agent, session_id)` and embeddings upsert by entry id.

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

    /// Bring both the text index and the embeddings up to date.
    ///
    /// Progress: `onProgress(done, total)` reports embedded entries out of
    /// all stored entries. It fires once before embedding starts (crediting
    /// entries embedded on earlier passes) and once per chunk after. The
    /// final call has `done == total` unless cancellation fired.
    public func refresh(
        batchSize: Int = 64,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws {
        try await indexText()
        try await embedPending(batchSize: batchSize, onProgress: onProgress)
    }

    /// Phase 1: store new message text from every adapter.
    ///
    /// For each adapter: read its cursor, ask it for entries past the
    /// cursor, insert them (duplicates are dropped by the unique key), then
    /// persist the new cursor. The cursor is written only after the insert
    /// succeeds, so a cancellation re-walks the same entries next time and
    /// the dedup drops the ones already stored.
    public func indexText() async throws {
        for adapter in adapters {
            try Task.checkCancellation()
            let cursor = try await store.readCursor(adapterName: adapter.name)
            let load = try await adapter.loadWithTitles(cursor: cursor)
            try await store.insertText(entries: load.entries)
            try await store.upsertTitles(load.titles)
            try Task.checkCancellation()
            try await store.writeCursor(adapterName: adapter.name, cursor: load.newCursor)
        }
    }

    /// Phase 2: embed every stored entry that has no vector yet, in chunks
    /// of `batchSize`.
    ///
    /// Worst-case cancellation latency is one chunk's embed time (~50ms per
    /// entry). CoreML prediction is synchronous, so an in-flight chunk runs
    /// to completion. Each chunk's vectors are stored before the next
    /// chunk starts, so cancelled work is never redone.
    public func embedPending(
        batchSize: Int = 64,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws {
        let total = try await store.entryCount()
        var done = try await store.embeddingCount()
        onProgress?(done, total)

        let chunkSize = max(1, batchSize)
        while true {
            try Task.checkCancellation()
            let chunk = try await store.entriesMissingEmbeddings(limit: chunkSize)
            guard !chunk.isEmpty else { return }
            let vectors = try await embedder.encode(
                chunk.map(\.text),
                batchSize: chunk.count,
                onProgress: nil
            )
            precondition(
                vectors.count == chunk.count,
                "Indexer: embedder returned \(vectors.count) vectors for \(chunk.count) inputs"
            )
            try await store.insertEmbeddings(ids: chunk.compactMap(\.id), vectors: vectors)
            // Capped: a concurrent text pass can add entries after `total`
            // was read, and this loop embeds those too.
            done = min(total, done + chunk.count)
            onProgress?(done, total)
        }
    }
}
