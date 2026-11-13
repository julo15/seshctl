// VectorStoreTests — covers the SQLite-backed embedding store: roundtrip,
// dedup, FK cascade, text-only inserts + embedding backfill, the FTS
// keyword index, cursors, and clearAll.
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

    @Test("insertText stores entries without embeddings; insertEmbeddings backfills them")
    func textThenEmbeddings() async throws {
        let store = try makeStore()
        let entries = (0..<3).map { makeEntry(seed: $0) }

        let ids = try await store.insertText(entries: entries)
        #expect(ids.count == 3)
        #expect(try await store.entryCount() == 3)
        #expect(try await store.embeddingCount() == 0)

        let pending = try await store.entriesMissingEmbeddings(limit: 10)
        #expect(pending.map(\.id) == ids, "oldest id first")

        try await store.insertEmbeddings(ids: [ids[0], ids[1]], vectors: [makeVector(seed: 0), makeVector(seed: 1)])
        #expect(try await store.embeddingCount() == 2)
        let stillPending = try await store.entriesMissingEmbeddings(limit: 10)
        #expect(stillPending.map(\.id) == [ids[2]])

        // Re-inserting the same text is a no-op.
        let again = try await store.insertText(entries: entries)
        #expect(again.isEmpty)
    }

    @Test("entriesMissingEmbeddings honors the limit")
    func missingEmbeddingsLimit() async throws {
        let store = try makeStore()
        _ = try await store.insertText(entries: (0..<5).map { makeEntry(seed: $0) })
        let pending = try await store.entriesMissingEmbeddings(limit: 2)
        #expect(pending.count == 2)
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

    @Test("keywordHits finds inserted text with marked snippets, best match first")
    func keywordHitsFindsText() async throws {
        let store = try makeStore()
        _ = try await store.insertText(entries: [
            makeTextEntry("the sparkle appcast is stale", seed: 1, sessionID: "S1"),
            makeTextEntry("sparkle appcast generation; regenerate the appcast after every appcast change", seed: 2, sessionID: "S2"),
            makeTextEntry("nothing relevant here", seed: 3, sessionID: "S3"),
        ])

        let candidates = try await store.keywordCandidates(match: #""appc"*"#, limit: 10)
        #expect(Set(candidates.map(\.sessionID)) == ["S1", "S2"])
        #expect(candidates.first?.sessionID == "S2", "more occurrences rank higher")
        #expect(candidates.allSatisfy { $0.rank < 0 }, "bm25 is negative; lower is better")

        let ids = candidates.map(\.id)
        let hits = try await store.keywordHits(match: #""appc"*"#, ids: ids)
        #expect(hits.compactMap(\.entry.id) == ids, "hits come back in the order asked for")
        let s1 = hits.first { $0.entry.sessionID == "S1" }
        #expect(s1?.entry.text == "the sparkle appcast is stale")
        #expect(s1?.snippet.contains("\(KeywordHit.matchStart)appcast\(KeywordHit.matchEnd)") == true)
    }

    @Test("keywordHits(match:ids:) drops ids that don't match and handles no ids")
    func keywordHitsDropsNonMatching() async throws {
        let store = try makeStore()
        let ids = try await store.insertText(entries: [
            makeTextEntry("sparkle appcast", seed: 1, sessionID: "S1"),
            makeTextEntry("unrelated", seed: 2, sessionID: "S2"),
        ])
        let hits = try await store.keywordHits(match: #""sparkle"*"#, ids: ids + [9_999])
        #expect(hits.map(\.entry.sessionID) == ["S1"])
        #expect(try await store.keywordHits(match: #""sparkle"*"#, ids: []).isEmpty)
    }

    @Test("FTS index follows updates: new text matches, old text doesn't")
    func keywordIndexFollowsUpdates() async throws {
        let db = try SeshctlDatabase.temporary()
        let store = VectorStore(database: db)
        _ = try await store.insertText(entries: [makeTextEntry("sparkle appcast", seed: 1, sessionID: "S1")])
        try await db.dbPool.write { rawDB in
            try rawDB.execute(sql: "UPDATE recall_entries SET text = 'zombie reaper'")
        }
        #expect(try await store.keywordCandidates(match: #""zombie"*"#, limit: 10).count == 1)
        #expect(try await store.keywordCandidates(match: #""sparkle"*"#, limit: 10).isEmpty)
        try await db.dbPool.write { rawDB in
            try rawDB.execute(sql: "INSERT INTO recall_fts(recall_fts, rank) VALUES ('integrity-check', 1)")
        }
    }

    @Test("insertText truncates oversized text but keeps the full-text hash")
    func insertTextTruncatesOversizedText() async throws {
        let store = try makeStore()
        let huge = String(repeating: "x", count: HistoryEntry.maxStoredTextLength) + " tailword"
        let entry = HistoryEntry(
            id: nil, agent: "claude", role: "user", sessionID: "S1", project: "/p",
            timestamp: 1, text: huge, textHash: HistoryEntry.textHash(for: huge)
        )
        let ids = try await store.insertText(entries: [entry])
        let stored = try await store.entries(forIDs: ids)
        #expect(stored.first?.text.count == HistoryEntry.maxStoredTextLength)
        #expect(stored.first?.textHash == HistoryEntry.textHash(for: huge))
        #expect(try await store.keywordCandidates(match: #""tailword""#, limit: 10).isEmpty)
        // Re-inserting the same full text still dedupes.
        #expect(try await store.insertText(entries: [entry]).isEmpty)
    }

    @Test("insertText spans several write batches")
    func insertTextSpansBatches() async throws {
        let store = try makeStore()
        let count = VectorStore.insertTextBatchSize * 2 + 7
        let entries = (0..<count).map { makeTextEntry("row \($0)", seed: $0, sessionID: "S") }
        let ids = try await store.insertText(entries: entries)
        #expect(ids.count == count)
        #expect(try await store.entryCount() == count)
    }

    @Test("v17 migration truncates text stored before the cap")
    func migrationTruncatesOversizedRows() async throws {
        let db = try SeshctlDatabase.temporary()
        let store = VectorStore(database: db)
        _ = try await store.insertText(entries: [makeTextEntry("short", seed: 1, sessionID: "S1")])
        // Simulate a pre-cap row, then run the migration's statement.
        let long = String(repeating: "y", count: 150_000)
        try await db.dbPool.write { rawDB in
            try rawDB.execute(sql: "UPDATE recall_entries SET text = ?", arguments: [long])
            try rawDB.execute(sql: SeshctlDatabase.truncateOversizedRecallTextSQL)
        }
        let length = try await db.dbPool.read { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT length(text) FROM recall_entries")
        }
        #expect(length == HistoryEntry.maxStoredTextLength)
    }

    @Test("keywordHits requires every term")
    func keywordHitsRequiresAllTerms() async throws {
        let store = try makeStore()
        _ = try await store.insertText(entries: [
            makeTextEntry("zombie process reaper", seed: 1, sessionID: "S1"),
            makeTextEntry("zombie movie night", seed: 2, sessionID: "S2"),
        ])
        let hits = try await store.keywordCandidates(match: #""zombie"* "reaper"*"#, limit: 10)
        #expect(hits.map(\.sessionID) == ["S1"])
    }

    @Test("FTS index follows deletes, so cleared entries stop matching")
    func keywordIndexFollowsDeletes() async throws {
        let store = try makeStore()
        _ = try await store.insertText(entries: [makeTextEntry("sparkle appcast", seed: 1, sessionID: "S1")])
        #expect(try await store.keywordCandidates(match: #""sparkle"*"#, limit: 10).count == 1)

        try await store.clearAllEntriesAndEmbeddings()
        #expect(try await store.keywordCandidates(match: #""sparkle"*"#, limit: 10).isEmpty)
    }

    @Test("entries(agent:sessionID:) returns one session's messages oldest first")
    func entriesForSessionOrdered() async throws {
        let store = try makeStore()
        _ = try await store.insertText(entries: [
            makeEntry(seed: 3, role: "assistant"),
            makeEntry(seed: 1),
            makeEntry(seed: 2, sessionID: "session-B"),
            makeEntry(seed: 4, agent: "codex"),
        ])
        let entries = try await store.entries(agent: "claude", sessionID: "session-A")
        #expect(entries.map(\.text) == ["entry-1", "entry-3"])
        #expect(try await store.entries(agent: "claude", sessionID: "missing").isEmpty)
    }

    @Test("HistoryEntry.conversationTurn maps user and assistant, drops other roles")
    func historyEntryConversationTurn() {
        let date = Date(timeIntervalSince1970: 1_700_000_001)
        #expect(makeEntry(seed: 1).conversationTurn == .userMessage(text: "entry-1", timestamp: date))
        #expect(
            makeEntry(seed: 1, role: "assistant").conversationTurn
                == .assistantMessage(text: "entry-1", toolCalls: [], timestamp: date)
        )
        #expect(makeEntry(seed: 1, role: "system").conversationTurn == nil)
    }

    @Test("Migration backfills the FTS index from entries stored before it existed")
    func migrationBackfillsExistingEntries() async throws {
        let db = try SeshctlDatabase.temporary()
        let store = VectorStore(database: db)
        // Simulate rows written before v16: insert, then wipe the index and
        // rebuild it the way the migration does.
        _ = try await store.insertText(entries: [makeTextEntry("legacy appcast row", seed: 1, sessionID: "S1")])
        try await db.dbPool.write { rawDB in
            try rawDB.execute(sql: "INSERT INTO recall_fts(recall_fts) VALUES ('delete-all')")
        }
        #expect(try await store.keywordCandidates(match: #""legacy"*"#, limit: 10).isEmpty)

        try await db.dbPool.write { rawDB in
            try rawDB.execute(sql: "INSERT INTO recall_fts(recall_fts) VALUES ('rebuild')")
        }
        #expect(try await store.keywordCandidates(match: #""legacy"*"#, limit: 10).count == 1)
    }

    @Test("upsertTitles keeps stored fields that a later pass leaves nil")
    func upsertTitlesCoalesces() async throws {
        let store = try makeStore()
        try await store.upsertTitles([IndexedTitle(agent: "claude", sessionID: "S", aiTitle: "AI", customTitle: nil)])
        try await store.upsertTitles([IndexedTitle(agent: "claude", sessionID: "S", aiTitle: nil, customTitle: "Custom")])
        #expect(try await store.sessionTitle(agent: "claude", sessionID: "S") == "AI", "ai-title wins over custom-title")

        try await store.upsertTitles([IndexedTitle(agent: "claude", sessionID: "T", aiTitle: nil, customTitle: "Only custom")])
        #expect(try await store.sessionTitle(agent: "claude", sessionID: "T") == "Only custom")
        try await store.upsertTitles([])
    }

    @Test("sessionTitle falls back to the first typed user message, on one line")
    func sessionTitleFallsBackToFirstMessage() async throws {
        let store = try makeStore()
        func entry(_ text: String, role: String = "user", seed: Int, session: String = "S") -> HistoryEntry {
            HistoryEntry(
                id: nil, agent: "claude", role: role, sessionID: session, project: "/p",
                timestamp: Double(seed), text: text, textHash: HistoryEntry.textHash(for: text)
            )
        }
        let long = String(repeating: "word ", count: 60)
        _ = try await store.insertText(entries: [
            entry("assistant goes first", role: "assistant", seed: 0),
            entry("<command-name>/foo</command-name>", seed: 1),
            entry("fix the\n  reaper   bug", seed: 2),
            entry("later ask", seed: 3),
            entry(long, seed: 1, session: "L"),
        ])
        #expect(try await store.sessionTitle(agent: "claude", sessionID: "S") == "fix the reaper bug")

        let longTitle = try await store.sessionTitle(agent: "claude", sessionID: "L")
        #expect(longTitle?.count == VectorStore.firstMessageTitleLength)
        #expect(longTitle?.hasSuffix("…") == true)

        #expect(try await store.sessionTitle(agent: "claude", sessionID: "missing") == nil)
        #expect(try await store.sessionTitle(agent: "codex", sessionID: "S") == nil, "keyed by agent too")
    }


    @Test("titleMatches finds indexed and picked titles, follows updates, one row per session")
    func titleMatchesFollowsTitleTables() async throws {
        let db = try SeshctlDatabase.temporary()
        let store = VectorStore(database: db)
        try await store.upsertTitles([
            IndexedTitle(agent: "claude", sessionID: "A", aiTitle: "Sparkle appcast fix", customTitle: "appcast box"),
            IndexedTitle(agent: "claude", sessionID: "B", aiTitle: "Zombie reaper", customTitle: nil),
        ])
        try db.setConversationTitle(conversationId: "C", tool: .codex, title: "Appcast signing")

        let matches = try await store.titleMatches(match: #""appc"*"#, limit: 10)
        #expect(Set(matches.map(\.sessionKey)) == ["claude|A", "codex|C"], "one row per session")
        let marked = matches.first { $0.sessionID == "C" }?.marked
        #expect(marked == "\(KeywordHit.matchStart)Appcast\(KeywordHit.matchEnd) signing")

        // Renames replace the old title in the index.
        try await store.upsertTitles([IndexedTitle(agent: "claude", sessionID: "B", aiTitle: "Process cleanup", customTitle: nil)])
        try db.setConversationTitle(conversationId: "C", tool: .codex, title: "Release notes")
        #expect(try await store.titleMatches(match: #""zombie"*"#, limit: 10).isEmpty)
        #expect(try await store.titleMatches(match: #""cleanup"*"#, limit: 10).map(\.sessionID) == ["B"])
        #expect(try await store.titleMatches(match: #""appc"*"#, limit: 10).map(\.sessionID) == ["A"])

        // Deletes drop out too.
        try await db.dbPool.write { rawDB in
            try rawDB.execute(sql: "DELETE FROM recall_titles WHERE session_id = 'A'")
            try rawDB.execute(sql: "DELETE FROM conversation_titles")
        }
        #expect(try await store.titleMatches(match: #""appc"*"#, limit: 10).isEmpty)
        #expect(try await store.titleMatches(match: #""release"*"#, limit: 10).isEmpty)
    }

    @Test("latestEntry returns a session's newest message")
    func latestEntryIsNewest() async throws {
        let store = try makeStore()
        _ = try await store.insertText(entries: [
            makeTextEntry("older", seed: 1, sessionID: "S"),
            makeTextEntry("newer", seed: 2, sessionID: "S"),
            makeTextEntry("other session", seed: 3, sessionID: "T"),
        ])
        #expect(try await store.latestEntry(agent: "claude", sessionID: "S")?.text == "newer")
        #expect(try await store.latestEntry(agent: "claude", sessionID: "missing") == nil)
    }

    @Test("fillFallbackTitles names untitled sessions by their first typed message; a real title replaces it")
    func fillFallbackTitlesLifecycle() async throws {
        let store = try makeStore()
        func userEntry(_ text: String, seed: Int, session: String) -> HistoryEntry {
            HistoryEntry(
                id: nil, agent: "claude", role: "user", sessionID: session, project: "/p",
                timestamp: Double(seed), text: text, textHash: HistoryEntry.textHash(for: text)
            )
        }
        _ = try await store.insertText(entries: [
            userEntry("messenger bag research", seed: 1, session: "U"),
            userEntry("<command-name>/x</command-name>", seed: 1, session: "LATER"),
            userEntry("already titled", seed: 1, session: "T"),
        ])
        try await store.upsertTitles([IndexedTitle(agent: "claude", sessionID: "T", aiTitle: "Real title", customTitle: nil)])
        try await store.fillFallbackTitles()

        #expect(try await store.titleMatches(match: #""messenger"*"#, limit: 10).map(\.sessionID) == ["U"])
        #expect(try await store.titleMatches(match: #""already"*"#, limit: 10).isEmpty, "titled sessions get no fallback")
        #expect(try await store.sessionTitle(agent: "claude", sessionID: "LATER") == nil)

        // A session with no typed message yet is picked up once it has one.
        _ = try await store.insertText(entries: [userEntry("typed at last", seed: 2, session: "LATER")])
        try await store.fillFallbackTitles()
        #expect(try await store.sessionTitle(agent: "claude", sessionID: "LATER") == "typed at last")
        #expect(try await store.titleMatches(match: #""typed"*"#, limit: 10).map(\.sessionID) == ["LATER"])

        // A real title arriving later replaces the fallback, in display and search.
        try await store.upsertTitles([IndexedTitle(agent: "claude", sessionID: "U", aiTitle: "Bag shopping", customTitle: nil)])
        #expect(try await store.sessionTitle(agent: "claude", sessionID: "U") == "Bag shopping")
        #expect(try await store.titleMatches(match: #""messenger"*"#, limit: 10).isEmpty)
        #expect(try await store.titleMatches(match: #""shopping"*"#, limit: 10).map(\.sessionID) == ["U"])
    }
}

private func makeTextEntry(_ text: String, seed: Int, sessionID: String) -> HistoryEntry {
    HistoryEntry(
        id: nil,
        agent: "claude",
        role: "assistant",
        sessionID: sessionID,
        project: "/tmp/project",
        timestamp: 1_700_000_000 + Double(seed),
        text: text,
        textHash: HistoryEntry.textHash(for: text)
    )
}
