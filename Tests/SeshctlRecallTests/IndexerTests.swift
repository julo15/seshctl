// IndexerTests — end-to-end: mock adapter → real EmbeddingService → real
// VectorStore. Skips when the Phase 1 spike's .mlpackage isn't on disk
// (same gate as `EmbeddingServiceTests`) — CI will hit the skip path until
// Phase 7 bundles the model.

import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlRecall

// MARK: - Spike-artifact resolver (same shape as EmbeddingServiceTests).

private func repoRoot() -> URL {
    var url = URL(fileURLWithPath: #file)
    while url.path != "/" {
        url = url.deletingLastPathComponent()
        let candidate = url.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return url
        }
    }
    fatalError("could not find Package.swift walking up from \(#file)")
}

private struct SpikeArtifacts {
    let modelURL: URL
    let tokenizerFolderURL: URL

    static func resolveIfAvailable() -> SpikeArtifacts? {
        let root = repoRoot()
        let spikeDir = root.appendingPathComponent(".agents/spikes/2026-05-25-recall-spike")
        let modelURL = spikeDir.appendingPathComponent("all-MiniLM-L6-v2-int8.mlpackage")
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelURL.path) else { return nil }
        guard fm.fileExists(atPath: spikeDir.appendingPathComponent("tokenizer.json").path),
              fm.fileExists(atPath: spikeDir.appendingPathComponent("tokenizer_config.json").path)
        else { return nil }
        return SpikeArtifacts(modelURL: modelURL, tokenizerFolderURL: spikeDir)
    }
}

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

private func makeService() async throws -> EmbeddingService? {
    guard let artifacts = SpikeArtifacts.resolveIfAvailable() else { return nil }
    return try await EmbeddingService(
        modelURL: artifacts.modelURL,
        tokenizerFolderURL: artifacts.tokenizerFolderURL
    )
}

// MARK: - Tests.

@Suite("Indexer")
struct IndexerTests {
    @Test("refresh embeds + persists every adapter entry, advances cursor")
    func refreshEmbedsAndPersists() async throws {
        guard let service = try await makeService() else { return }
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
        guard let service = try await makeService() else { return }
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
        guard let service = try await makeService() else { return }
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
        // One callback per adapter (with non-empty entries) = 2 calls.
        #expect(calls.count == 2, "expected one progress call per adapter, got \(calls)")
        // Both callbacks must satisfy done == total at the moment they
        // fire — Indexer increments both by the same amount.
        for (done, total) in calls {
            #expect(done == total, "expected done == total in cumulative progress, got \(done)/\(total)")
        }
        // Final total is the cumulative count across both adapters.
        #expect(calls.last?.1 == 5)
    }

    @Test("refresh rebuilds on drift before walking adapters")
    func refreshOnDriftRebuilds() async throws {
        guard let service = try await makeService() else { return }
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
}
