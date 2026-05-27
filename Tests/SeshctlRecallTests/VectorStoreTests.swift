// VectorStoreTests — covers the SQLite-backed embedding store: roundtrip,
// dedup, FK cascade, drift detection, cursors, and clearAll.
//
// All tests build a fresh `SeshctlDatabase.temporary()` so they're hermetic
// and parallel-safe (no shared on-disk state).

import Foundation
import GRDB
import Testing

@testable import SeshctlCore
@testable import SeshctlRecall

// MARK: - Helpers.

private func makeStore() throws -> VectorStore {
    let db = try SeshctlDatabase.temporary()
    return VectorStore(database: db)
}

private func makeEntry(
    seed: Int,
    agent: String = "claude",
    role: String = "user",
    sessionID: String = "session-A"
) -> HistoryEntry {
    let text = "entry-\(seed)"
    return HistoryEntry(
        id: nil,
        agent: agent,
        role: role,
        sessionID: sessionID,
        project: "/tmp/project",
        timestamp: 1_700_000_000 + Double(seed),
        text: text,
        textHash: HistoryEntry.textHash(for: text)
    )
}

private func makeVector(seed: Int, dim: Int = 384) -> [Float] {
    // Deterministic per-seed, distinguishable across seeds. Not unit-norm
    // (the store doesn't normalize — that's EmbeddingService's job).
    (0..<dim).map { i in Float(seed) + Float(i) * 0.001 }
}

// MARK: - Tests.

@Suite("VectorStore")
struct VectorStoreTests {
    @Test("insert + retrieve roundtrip is byte-identical for 5 entries")
    func insertAndRetrieveRoundtrip() async throws {
        let store = try makeStore()
        let entries = (0..<5).map { makeEntry(seed: $0) }
        let vectors = (0..<5).map { makeVector(seed: $0) }

        let insertedIDs = try await store.insert(entries: entries, embeddings: vectors)
        #expect(insertedIDs.count == 5)

        let (loadedIDs, loadedVectors) = try await store.loadAllEmbeddings()
        #expect(loadedIDs == insertedIDs.sorted())
        #expect(loadedVectors.count == 5)
        for (i, expected) in vectors.enumerated() {
            #expect(loadedVectors[i] == expected, "vector \(i) didn't roundtrip exactly")
        }

        let hydrated = try await store.entries(forIDs: insertedIDs)
        #expect(hydrated.count == 5)
        for (i, entry) in entries.enumerated() {
            #expect(hydrated[i].text == entry.text)
            #expect(hydrated[i].textHash == entry.textHash)
            #expect(hydrated[i].timestamp == entry.timestamp)
            #expect(hydrated[i].agent == entry.agent)
            #expect(hydrated[i].id == insertedIDs[i])
        }
    }

    @Test("Inserting the same textHash twice in one session yields exactly one row")
    func dedupOnSameSessionTextHash() async throws {
        let store = try makeStore()
        let entry = makeEntry(seed: 42)
        let vector = makeVector(seed: 42)

        let firstIDs = try await store.insert(entries: [entry], embeddings: [vector])
        #expect(firstIDs.count == 1)

        let secondIDs = try await store.insert(entries: [entry], embeddings: [vector])
        #expect(secondIDs.isEmpty, "duplicate insert should return no new ids")

        let count = try await store.entryCount()
        #expect(count == 1)

        let (loadedIDs, _) = try await store.loadAllEmbeddings()
        #expect(loadedIDs.count == 1, "duplicate insert should not create a stranded embedding")
    }

    @Test("Identical text in different sessions both get indexed (composite dedup key)")
    func crossSessionTextHashSurvives() async throws {
        let db = try SeshctlDatabase.temporary()
        let store = VectorStore(database: db)
        let sharedText = "ok"
        let sharedHash = HistoryEntry.textHash(for: sharedText)
        let e1 = HistoryEntry(
            id: nil, agent: "claude", role: "user",
            sessionID: "session-A", project: "/a",
            timestamp: 1.0, text: sharedText, textHash: sharedHash
        )
        let e2 = HistoryEntry(
            id: nil, agent: "claude", role: "user",
            sessionID: "session-B", project: "/b",
            timestamp: 2.0, text: sharedText, textHash: sharedHash
        )
        let v = [Float](repeating: 0.1, count: 384)
        let ids1 = try await store.insert(entries: [e1], embeddings: [v])
        let ids2 = try await store.insert(entries: [e2], embeddings: [v])
        #expect(ids1.count == 1)
        #expect(ids2.count == 1)
        #expect(try await store.entryCount() == 2, "both sessions' identical text should survive")
    }

    @Test("Deleting recall_entries cascades to recall_embeddings via FK")
    func deleteCascade() async throws {
        let db = try SeshctlDatabase.temporary()
        let store = VectorStore(database: db)
        let entries = (0..<3).map { makeEntry(seed: $0) }
        let vectors = (0..<3).map { makeVector(seed: $0) }
        _ = try await store.insert(entries: entries, embeddings: vectors)

        // Sanity: 3 rows in each table.
        let beforeEntries = try await store.entryCount()
        #expect(beforeEntries == 3)
        let (beforeEmbedIDs, _) = try await store.loadAllEmbeddings()
        #expect(beforeEmbedIDs.count == 3)

        // Raw DELETE on recall_entries — cascade should clear embeddings too.
        try await db.dbPool.write { rawDB in
            try rawDB.execute(sql: "DELETE FROM recall_entries")
        }

        let afterEntries = try await store.entryCount()
        #expect(afterEntries == 0)
        let (afterEmbedIDs, _) = try await store.loadAllEmbeddings()
        #expect(afterEmbedIDs.isEmpty, "FK cascade should have cleared embeddings")
    }

    @Test("detectDrift is false on balanced store, true when embeddings diverge")
    func driftDetection() async throws {
        let db = try SeshctlDatabase.temporary()
        let store = VectorStore(database: db)
        let entries = (0..<3).map { makeEntry(seed: $0) }
        let vectors = (0..<3).map { makeVector(seed: $0) }
        _ = try await store.insert(entries: entries, embeddings: vectors)

        let driftBefore = try await store.detectDrift()
        #expect(driftBefore == false, "fresh balanced store should not drift")

        // Surgically remove one embedding row (FK doesn't fire — we're
        // deleting from the child, not the parent).
        try await db.dbPool.write { rawDB in
            try rawDB.execute(sql: "DELETE FROM recall_embeddings WHERE entry_id = (SELECT MIN(entry_id) FROM recall_embeddings)")
        }

        let driftAfter = try await store.detectDrift()
        #expect(driftAfter == true, "store should report drift after manual embedding deletion")
    }

    @Test("Cursor read/write roundtrip + nil for unknown adapters")
    func cursorRoundtrip() async throws {
        let store = try makeStore()

        let unknown = try await store.readCursor(adapterName: "codex")
        #expect(unknown == nil)

        let payload = Data(#"{"path/a":1.0,"path/b":2.5}"#.utf8)
        try await store.writeCursor(adapterName: "claude", cursor: payload)

        let read = try await store.readCursor(adapterName: "claude")
        #expect(read == payload)

        // Update overwrites.
        let next = Data(#"{"path/a":99.0}"#.utf8)
        try await store.writeCursor(adapterName: "claude", cursor: next)
        let reread = try await store.readCursor(adapterName: "claude")
        #expect(reread == next)

        // Other adapters remain nil.
        let stillUnknown = try await store.readCursor(adapterName: "gemini")
        #expect(stillUnknown == nil)
    }

    @Test("clearAllEntriesAndEmbeddings wipes both tables + cursors")
    func clearAll() async throws {
        let store = try makeStore()
        let entries = (0..<4).map { makeEntry(seed: $0) }
        let vectors = (0..<4).map { makeVector(seed: $0) }
        _ = try await store.insert(entries: entries, embeddings: vectors)
        try await store.writeCursor(adapterName: "claude", cursor: Data("{}".utf8))

        try await store.clearAllEntriesAndEmbeddings()

        let entryCount = try await store.entryCount()
        #expect(entryCount == 0)
        let (embedIDs, _) = try await store.loadAllEmbeddings()
        #expect(embedIDs.isEmpty)
        let cursor = try await store.readCursor(adapterName: "claude")
        #expect(cursor == nil)
    }

    @Test("entries(forIDs:) preserves caller order and drops unknowns")
    func entriesPreserveOrder() async throws {
        let store = try makeStore()
        let entries = (0..<3).map { makeEntry(seed: $0) }
        let vectors = (0..<3).map { makeVector(seed: $0) }
        let ids = try await store.insert(entries: entries, embeddings: vectors)
        #expect(ids.count == 3)

        // Request in reverse order with one bogus id mixed in.
        let request = [ids[2], 99_999, ids[0], ids[1]]
        let hydrated = try await store.entries(forIDs: request)
        #expect(hydrated.count == 3)
        #expect(hydrated[0].text == entries[2].text)
        #expect(hydrated[1].text == entries[0].text)
        #expect(hydrated[2].text == entries[1].text)
    }

    @Test("entryCount on an empty store is zero")
    func entryCountEmpty() async throws {
        let store = try makeStore()
        let count = try await store.entryCount()
        #expect(count == 0)
    }

    @Test("HistoryEntry.textHash is stable + lowercase hex")
    func textHashStable() {
        let h1 = HistoryEntry.textHash(for: "hello world")
        let h2 = HistoryEntry.textHash(for: "hello world")
        #expect(h1 == h2)
        #expect(h1.count == 64, "SHA-256 hex = 64 chars")
        #expect(h1.allSatisfy { "0123456789abcdef".contains($0) })
        let different = HistoryEntry.textHash(for: "hello world!")
        #expect(h1 != different)
    }
}
