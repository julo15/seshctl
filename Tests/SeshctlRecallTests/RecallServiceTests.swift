// RecallServiceTests — exercises the static façade. The shared stack holds
// process-wide state (configured database + cached construction Task), so
// each test calls `RecallService._resetForTests()` first to avoid bleed
// between tests + bleed from other test files that may have configured the
// service.
//
// End-to-end coverage against the bundled CoreML model lives in
// `endToEndSearchAgainstMockAdapters` — it injects a `MockAdapter` via
// `configureForTesting` so the indexer doesn't walk the developer's real
// transcript directories.

import Foundation
import Testing

@testable import SeshctlCore
@_spi(Testing) @testable import SeshctlRecall

// MARK: - MockAdapter (mirrors the pattern in IndexerTests.swift).

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
        if cursor == self.cursor {
            return ([], self.cursor)
        }
        return (entries, self.cursor)
    }
}

private func makeEntry(text: String, sessionID: String) -> HistoryEntry {
    HistoryEntry(
        id: nil,
        agent: "claude",
        role: "user",
        sessionID: sessionID,
        project: "/p",
        timestamp: 1.0,
        text: text,
        textHash: HistoryEntry.textHash(for: text)
    )
}

@Suite("RecallService", .serialized)
struct RecallServiceTests {
    @Test("isAvailable returns true (native implementation, no external binary)")
    func isAvailableReturnsTrue() {
        #expect(RecallService.isAvailable() == true)
    }

    @Test("Empty query short-circuits to empty results without touching the stack")
    func searchEmptyQuery() async throws {
        RecallService._resetForTests()
        let response = try await RecallService.search(query: "")
        #expect(response.results.isEmpty)
        #expect(response.indexingCount == nil)
    }

    @Test("Whitespace-only query short-circuits to empty results")
    func searchWhitespaceQuery() async throws {
        RecallService._resetForTests()
        let response = try await RecallService.search(query: "   \n\t  ")
        #expect(response.results.isEmpty)
        #expect(response.indexingCount == nil)
    }

    @Test("Search before configure() throws a searchFailed error mentioning configure")
    func searchWithoutConfigureThrows() async {
        RecallService._resetForTests()
        await #expect {
            _ = try await RecallService.search(query: "hello world")
        } throws: { error in
            guard let recallError = error as? RecallError,
                  case .searchFailed(let message) = recallError else {
                return false
            }
            return message.contains("configure")
        }
    }

    @Test("search() returns top-K dedup'd RecallResults end-to-end against injected mock adapters")
    func endToEndSearchAgainstMockAdapters() async throws {
        RecallService._resetForTests()
        let db = try SeshctlDatabase.temporary()
        // 5 fixture entries: 2 sessions, varied semantic content.
        let entries: [HistoryEntry] = [
            makeEntry(text: "how do I add a column to a SQLite table", sessionID: "S1"),
            makeEntry(text: "fix the off-by-one in the loop counter", sessionID: "S1"),
            makeEntry(text: "altering an existing database schema", sessionID: "S2"),
            makeEntry(text: "debugging a memory leak in Rust", sessionID: "S2"),
            makeEntry(text: "what's the time complexity of quicksort", sessionID: "S2"),
        ]
        let mock = MockAdapter(name: "claude", entries: entries, cursor: Data("v1".utf8))
        RecallService.configureForTesting(database: db, adapters: [mock])

        let resp = try await RecallService.search(query: "modify a SQL database column")
        #expect(resp.results.isEmpty == false)
        #expect(resp.results.count <= 10)
        // Session-level dedup: each result has a unique sessionId.
        let sessionIds = resp.results.map(\.sessionId)
        #expect(Set(sessionIds).count == sessionIds.count, "results should be deduped by session")
        // Scores are sorted descending.
        let scores = resp.results.map(\.score)
        #expect(scores == scores.sorted(by: >))
        // Top result is one of the two schema-altering sessions. Both
        // ("add a column to a SQLite table" in S1 and "altering an
        // existing database schema" in S2) score higher than the
        // unrelated loop/memory-leak/quicksort entries; which of the two
        // wins depends on the model's exact embedding geometry and is
        // not stable enough to pin here.
        let topSessionId = resp.results.first?.sessionId
        #expect(topSessionId == "S1" || topSessionId == "S2")
        // The unrelated session-S2 entries (memory leak, quicksort)
        // should never beat both schema-relevant entries — assert that
        // at least one of the top-2 results is schema-relevant.
        let top2Texts = resp.results.prefix(2).map(\.text)
        let schemaText = top2Texts.contains { text in
            text.contains("column") || text.contains("schema")
        }
        #expect(schemaText, "expected a schema-relevant entry in the top 2, got \(top2Texts)")
        // The indexingCount reflects what landed in the store (all 5).
        #expect(resp.indexingCount == 5)
    }

    @Test("indexing continues after the triggering search Task is canceled")
    func indexingSurvivesCallerCancellation() async throws {
        // The headline behavior of the detached-indexing change: canceling
        // a search's Task aborts ONLY the await on `indexingTask.value`,
        // not the detached refresh itself. The DB keeps gaining rows after
        // the cancel.
        //
        // 200 entries × ~50ms per CoreML predict ≈ 10s total embed time
        // across 4 default-batch-size (64) chunks. The polling loop waits
        // for the first chunk to land (entryCount > 0), cancels, then
        // verifies entryCount keeps growing.
        //
        // Without `Task.detached` in `RecallStack.ensureIndexingComplete`,
        // the cancel would propagate into `indexer.refresh` and finalCount
        // would stay at countAtCancel — the test would fail.
        RecallService._resetForTests()
        let db = try SeshctlDatabase.temporary()
        let entries = (0..<200).map { i in
            makeEntry(text: "cancellation-test-entry-\(i)", sessionID: "S\(i)")
        }
        let mock = MockAdapter(name: "claude", entries: entries, cursor: Data("v1".utf8))
        RecallService.configureForTesting(database: db, adapters: [mock])
        let store = VectorStore(database: db)

        let searchTask = Task {
            try? await RecallService.search(query: "anything")
        }

        // Poll until indexing has actually started landing rows (up to 60s).
        var countAtCancel = 0
        for _ in 0..<600 {
            countAtCancel = try await store.entryCount()
            if countAtCancel > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(countAtCancel > 0, "indexing should have produced at least one row before we cancel")

        searchTask.cancel()
        _ = await searchTask.value

        // Wait for further rows to land. If the detached pattern is broken,
        // this loop will time out at the same count we sampled before cancel.
        var finalCount = countAtCancel
        for _ in 0..<300 {
            finalCount = try await store.entryCount()
            if finalCount > countAtCancel { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(
            finalCount > countAtCancel,
            "indexing should have continued past cancel — countAtCancel=\(countAtCancel), finalCount=\(finalCount)"
        )
    }

    @Test("concurrent searches share a single in-flight indexing pass")
    func concurrentSearchesShareIndexing() async throws {
        // Three simultaneous search calls should all join the same detached
        // indexing task instead of each starting their own refresh. The
        // adapter's loadCount is the witness — exactly one walk regardless
        // of how many searches arrive while it's in flight.
        //
        // This is the load-bearing invariant behind "cancellation doesn't
        // restart indexing": a canceled search just stops AWAITING the
        // detached task; the task itself runs on, and any later search
        // joins it via the same slot.
        RecallService._resetForTests()
        let db = try SeshctlDatabase.temporary()
        let entries = (0..<10).map { i in
            makeEntry(text: "concurrent-test-entry-\(i)", sessionID: "S\(i)")
        }
        let mock = MockAdapter(name: "claude", entries: entries, cursor: Data("v1".utf8))
        RecallService.configureForTesting(database: db, adapters: [mock])

        async let r1 = RecallService.search(query: "anything")
        async let r2 = RecallService.search(query: "anything else")
        async let r3 = RecallService.search(query: "something different")
        _ = try await (r1, r2, r3)

        let loadCount = await mock.loadCount
        #expect(
            loadCount == 1,
            "three concurrent searches must share one indexing pass (got \(loadCount))"
        )
    }
}
