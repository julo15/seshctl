// IndexerTests — end-to-end: mock adapter → real EmbeddingService → real
// VectorStore. Uses the bundled `EmbeddingService()` (no-arg) so tests run
// unconditionally against the model + tokenizer in
// `Sources/SeshctlRecall/Models/`.

import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlRecall

// MARK: - MockAdapter.

/// Returns a canned set of entries on every `load` call and records how
/// many times it was invoked. `loadCount` is exposed as an async getter
/// because the counter is actor-isolated (Sendable in async contexts).
private actor MockAdapter: Adapter {
    nonisolated let name: String
    nonisolated let entries: [HistoryEntry]
    nonisolated let cursor: Data
    private var _loadCount: Int = 0

    init(name: String, entries: [HistoryEntry], cursor: Data) {
        self.name = name
        self.entries = entries
        self.cursor = cursor
    }

    var loadCount: Int { _loadCount }

    func load(cursor: Data?) async throws -> (entries: [HistoryEntry], newCursor: Data) {
        _loadCount += 1
        // Mimic the real adapter behavior: if the persisted cursor matches
        // ours, emit nothing — there's no new work since last walk.
        if cursor == self.cursor {
            return ([], self.cursor)
        }
        return (entries, self.cursor)
    }
}

// MARK: - Helpers.

private func makeEntry(seed: Int, agent: String = "claude") -> HistoryEntry {
    let text = "indexer-entry-\(agent)-\(seed)"
    return HistoryEntry(
        id: nil,
        agent: agent,
        role: "user",
        sessionID: "session-\(agent)",
        project: "/tmp/project",
        timestamp: 1_700_000_000 + Double(seed),
        text: text,
        textHash: HistoryEntry.textHash(for: text)
    )
}

// MARK: - Tests.

@Suite("Indexer")
struct IndexerTests {
    @Test("refresh embeds + persists every adapter entry, advances cursor")
    func refreshEmbedsAndPersists() async throws {
        let service = try await EmbeddingService()
        let db = try SeshctlDatabase.temporary()
        let store = VectorStore(database: db)
        let entries = (0..<10).map { makeEntry(seed: $0) }
        let cursorBody = Data(#"{"path/a":42.0}"#.utf8)
        let adapter = MockAdapter(name: "mock-claude", entries: entries, cursor: cursorBody)

        let indexer = Indexer(store: store, embedder: service, adapters: [adapter])
        try await indexer.refresh(batchSize: 4)

        let loadCount = await adapter.loadCount
        #expect(loadCount == 1)
        let count = try await store.entryCount()
        #expect(count == 10)
        let (ids, vectors) = try await store.loadAllEmbeddings()
        #expect(ids.count == 10)
        #expect(vectors.allSatisfy { $0.count == 384 })

        let cursor = try await store.readCursor(adapterName: "mock-claude")
        #expect(cursor == cursorBody)
    }

    @Test("refresh twice is idempotent — no duplicate inserts on second pass")
    func refreshSkipsAlreadyIndexed() async throws {
        let service = try await EmbeddingService()
        let db = try SeshctlDatabase.temporary()
        let store = VectorStore(database: db)
        let entries = (0..<5).map { makeEntry(seed: $0) }
        let adapter = MockAdapter(
            name: "mock-claude",
            entries: entries,
            cursor: Data("v1".utf8)
        )

        let indexer = Indexer(store: store, embedder: service, adapters: [adapter])
        try await indexer.refresh(batchSize: 4)
        try await indexer.refresh(batchSize: 4)

        // Adapter is called twice (once per refresh), but the second call
        // returns no new entries because the cursor matches.
        let loadCount = await adapter.loadCount
        #expect(loadCount == 2)
        let count = try await store.entryCount()
        #expect(count == 5, "second refresh shouldn't add rows")
    }

    @Test("progress callback fires with monotonically-growing done/total")
    func refreshProgressCallback() async throws {
        let service = try await EmbeddingService()
        let db = try SeshctlDatabase.temporary()
        let store = VectorStore(database: db)

        let claudeEntries = (0..<3).map { makeEntry(seed: $0, agent: "claude") }
        let codexEntries = (0..<2).map { makeEntry(seed: $0, agent: "codex") }
        let claudeAdapter = MockAdapter(
            name: "mock-claude",
            entries: claudeEntries,
            cursor: Data("c1".utf8)
        )
        let codexAdapter = MockAdapter(
            name: "mock-codex",
            entries: codexEntries,
            cursor: Data("x1".utf8)
        )

        actor ProgressSink {
            private(set) var calls: [(Int, Int)] = []
            func record(_ done: Int, _ total: Int) { calls.append((done, total)) }
            func snapshot() -> [(Int, Int)] { calls }
        }
        let sink = ProgressSink()

        let indexer = Indexer(
            store: store,
            embedder: service,
            adapters: [claudeAdapter, codexAdapter]
        )
        try await indexer.refresh(batchSize: 32, onProgress: { done, total in
            Task { await sink.record(done, total) }
        })

        for _ in 0..<10 { await Task.yield() }

        let calls = await sink.snapshot()
        // Per-batch progress is now lifted from embedder.encode into the
        // global progress space, so each adapter fires one callback per
        // embedding batch (here batchSize=32 → 1 batch for 3 claude entries
        // and 1 batch for 2 codex entries = 2 per-batch callbacks) PLUS
        // one final adapter-complete callback per adapter (2 more) = 4
        // total. Don't pin an exact count beyond "more than one per
        // adapter" — embedder batching is an implementation detail.
        #expect(calls.count >= 2, "expected at least one progress call per adapter, got \(calls)")
        // Every call must satisfy done <= total (cumulative bookkeeping is
        // monotonic — the per-batch lift never overshoots the snapshot).
        for (done, total) in calls {
            #expect(done <= total, "expected done <= total in cumulative progress, got \(done)/\(total)")
        }
        // done values across all calls are non-decreasing (monotonic growth).
        let doneValues = calls.map { $0.0 }
        let sortedDone = doneValues.sorted()
        #expect(doneValues == sortedDone, "expected done values to be non-decreasing, got \(doneValues)")
        // Final total is the cumulative count across both adapters.
        #expect(calls.last?.1 == 5)
        // Final done equals total — we finished embedding everything.
        #expect(calls.last?.0 == 5)
    }

    @Test("refresh rebuilds on drift before walking adapters")
    func refreshOnDriftRebuilds() async throws {
        let service = try await EmbeddingService()
        let db = try SeshctlDatabase.temporary()
        let store = VectorStore(database: db)

        // Pre-populate the store the normal way, then manually corrupt it
        // so entry/embedding counts diverge. Indexer's drift path should
        // clear the world before re-walking the mock adapter.
        let seedEntries = (0..<4).map { makeEntry(seed: $0, agent: "stale") }
        let seedVectors = seedEntries.map { _ in [Float](repeating: 0.1, count: 384) }
        _ = try await store.insert(entries: seedEntries, embeddings: seedVectors)
        try await store.writeCursor(adapterName: "mock-claude", cursor: Data("stale".utf8))
        try await db.dbPool.write { rawDB in
            // Drop one embedding so counts diverge.
            try rawDB.execute(sql: "DELETE FROM recall_embeddings WHERE entry_id = (SELECT MIN(entry_id) FROM recall_embeddings)")
        }
        let driftBefore = try await store.detectDrift()
        #expect(driftBefore == true)

        let freshEntries = (0..<3).map { makeEntry(seed: $0 + 100, agent: "claude") }
        let adapter = MockAdapter(
            name: "mock-claude",
            entries: freshEntries,
            cursor: Data("fresh".utf8)
        )

        let indexer = Indexer(store: store, embedder: service, adapters: [adapter])
        try await indexer.refresh(batchSize: 32)

        // Drift rebuild + adapter walk: exactly 3 fresh entries remain.
        let count = try await store.entryCount()
        #expect(count == 3, "drift rebuild + fresh walk should leave only the new entries")

        // No drift after rebuild.
        let driftAfter = try await store.detectDrift()
        #expect(driftAfter == false)

        // Cursor is the fresh one — stale cursor was wiped.
        let cursor = try await store.readCursor(adapterName: "mock-claude")
        #expect(cursor == Data("fresh".utf8))
    }

    @Test("refresh skips already-persisted entries (resume-after-cancel path)")
    func refreshSkipsAlreadyPersistedEntries() async throws {
        let service = try await EmbeddingService()
        let db = try SeshctlDatabase.temporary()
        let store = VectorStore(database: db)

        // Simulate: the prior refresh ran far enough to persist 4 of 7
        // entries into the DB but was canceled before writing the cursor.
        let allEntries = (0..<7).map { makeEntry(seed: $0) }
        let preExisting = Array(allEntries.prefix(4))
        // Dummy non-normalized vectors — this test exercises the resumability
        // path (insert + skip-already-indexed), not search quality, so the
        // vectors only need to be the right shape.
        let preVectors = preExisting.map { _ in [Float](repeating: 0.2, count: 384) }
        _ = try await store.insert(entries: preExisting, embeddings: preVectors)
        // NOTE: deliberately did NOT write the adapter's cursor — that's
        // the canceled-before-cursor-write state we're testing.

        // Adapter returns ALL 7 entries (it re-walked because cursor is nil).
        let adapter = MockAdapter(
            name: "mock-claude",
            entries: allEntries,
            cursor: Data("end".utf8)
        )

        actor ProgressSink {
            private(set) var calls: [(Int, Int)] = []
            func record(_ d: Int, _ t: Int) { calls.append((d, t)) }
            func snapshot() -> [(Int, Int)] { calls }
        }
        let sink = ProgressSink()

        let indexer = Indexer(store: store, embedder: service, adapters: [adapter])
        try await indexer.refresh(batchSize: 4, onProgress: { d, t in
            Task { await sink.record(d, t) }
        })
        for _ in 0..<10 { await Task.yield() }

        // All 7 are now in the DB (no dupes from the composite UNIQUE).
        let count = try await store.entryCount()
        #expect(count == 7)

        // Cursor is now written — adapter is "complete".
        let cursor = try await store.readCursor(adapterName: "mock-claude")
        #expect(cursor == Data("end".utf8))

        // Progress credits the 4 already-persisted entries up front, then
        // climbs as the remaining 3 finish embedding.
        let progress = await sink.snapshot()
        #expect(progress.isEmpty == false)
        // First progress fire should already be >= 4 (the resumed credit).
        #expect(progress.first!.0 >= 4, "expected the resumed credit before any embedding")
        // Final progress fire should be 7/7.
        #expect(progress.last?.0 == 7)
        #expect(progress.last?.1 == 7)
    }
}
