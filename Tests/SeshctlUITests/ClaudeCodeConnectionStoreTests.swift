import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

/// Stub `RemoteClaudeCodeFetching` for the instance-level store tests. Actor
/// isolation keeps the stored `Result` thread-safe; the payload is lazily
/// unwrapped in `refresh()`, so the same stub can serve many calls.
private actor StubFetcher: RemoteClaudeCodeFetching {
    private var result: Result<[RemoteClaudeCodeSession], Error>
    /// Per-id injection map. Tests insert before `fetchNow()`; the fetcher reads on call.
    private var assistantTextByID: [String: Result<String?, Error>] = [:]
    /// Per-id call count for assertions.
    private var assistantTextCalls: [String: Int] = [:]
    /// Optional sleep injected before returning from `fetchLatestAssistantText`,
    /// used by the disconnect-race test to keep tasks in flight long enough
    /// to be cancelled.
    private var assistantTextDelayNanos: UInt64 = 0

    init(result: Result<[RemoteClaudeCodeSession], Error>) {
        self.result = result
    }

    func setRefreshResult(_ result: Result<[RemoteClaudeCodeSession], Error>) {
        self.result = result
    }

    func setAssistantText(_ result: Result<String?, Error>, forSessionID id: String) {
        assistantTextByID[id] = result
    }

    func setAssistantTextDelay(nanoseconds: UInt64) {
        assistantTextDelayNanos = nanoseconds
    }

    func assistantTextCallCount(for id: String) -> Int {
        assistantTextCalls[id] ?? 0
    }

    func refresh() async throws -> [RemoteClaudeCodeSession] {
        try result.get()
    }

    func fetchLatestAssistantText(sessionId: String) async throws -> String? {
        assistantTextCalls[sessionId, default: 0] += 1
        if assistantTextDelayNanos > 0 {
            try await Task.sleep(nanoseconds: assistantTextDelayNanos)
        }
        if let result = assistantTextByID[sessionId] {
            return try result.get()
        }
        return nil
    }
}

private func makeRemoteSession(
    id: String = "cse_test_\(UUID().uuidString)",
    lastEventAt: Date = Date()
) -> RemoteClaudeCodeSession {
    RemoteClaudeCodeSession(
        id: id,
        title: "Test session",
        model: "claude-opus-4-7",
        repoUrl: "https://github.com/julo15/example",
        branches: ["main"],
        status: "active",
        workerStatus: "idle",
        connectionStatus: "connected",
        lastEventAt: lastEventAt,
        createdAt: Date(),
        unread: false
    )
}

// MARK: - stateForFetchResult (pure)

@Suite("ClaudeCodeConnectionStore.stateForFetchResult")
struct StateForFetchResultTests {

    @Test("success transitions to connected with recent lastFetchAt")
    func successTransition() {
        let before = Date()
        let state = ClaudeCodeConnectionStore.stateForFetchResult(
            .success([]),
            previouslyConnectedAt: nil
        )
        let after = Date()

        guard case .connected(let lastFetchAt) = state else {
            Issue.record("Expected .connected, got \(state)")
            return
        }
        #expect(lastFetchAt != nil)
        if let lastFetchAt {
            #expect(lastFetchAt >= before)
            #expect(lastFetchAt <= after)
        }
    }

    @Test("needsReauth transitions to authExpired")
    func needsReauthTransition() {
        let state = ClaudeCodeConnectionStore.stateForFetchResult(
            .failure(RemoteClaudeCodeError.needsReauth),
            previouslyConnectedAt: Date()
        )
        #expect(state == .authExpired)
    }

    @Test("notConnected transitions to notConnected")
    func notConnectedTransition() {
        let state = ClaudeCodeConnectionStore.stateForFetchResult(
            .failure(RemoteClaudeCodeError.notConnected),
            previouslyConnectedAt: nil
        )
        #expect(state == .notConnected)
    }

    @Test("http(500) transitions to transientError")
    func http500Transition() {
        let state = ClaudeCodeConnectionStore.stateForFetchResult(
            .failure(RemoteClaudeCodeError.http(500)),
            previouslyConnectedAt: Date()
        )
        guard case .transientError(let message) = state else {
            Issue.record("Expected .transientError, got \(state)")
            return
        }
        #expect(message.contains("500"))
    }

    @Test("decode error transitions to transientError")
    func decodeTransition() {
        let state = ClaudeCodeConnectionStore.stateForFetchResult(
            .failure(RemoteClaudeCodeError.decode("bad json")),
            previouslyConnectedAt: Date()
        )
        guard case .transientError(let message) = state else {
            Issue.record("Expected .transientError, got \(state)")
            return
        }
        #expect(message.contains("bad json"))
    }

    @Test("transport error transitions to transientError")
    func transportTransition() {
        let state = ClaudeCodeConnectionStore.stateForFetchResult(
            .failure(RemoteClaudeCodeError.transport("offline")),
            previouslyConnectedAt: Date()
        )
        guard case .transientError(let message) = state else {
            Issue.record("Expected .transientError, got \(state)")
            return
        }
        #expect(message.contains("offline"))
    }

    @Test("unknown error maps to transientError using localizedDescription")
    func unknownErrorTransition() {
        struct BogusError: Error, LocalizedError {
            var errorDescription: String? { "something weird" }
        }
        let state = ClaudeCodeConnectionStore.stateForFetchResult(
            .failure(BogusError()),
            previouslyConnectedAt: nil
        )
        guard case .transientError(let message) = state else {
            Issue.record("Expected .transientError, got \(state)")
            return
        }
        #expect(message == "something weird")
    }
}

// MARK: - Store instance tests

@Suite("ClaudeCodeConnectionStore")
@MainActor
struct ClaudeCodeConnectionStoreInstanceTests {

    @Test("fetchNow success transitions to connected")
    func fetchNowSuccessTransitions() async throws {
        let db = try SeshctlDatabase.temporary()
        let fetcher = StubFetcher(result: .success([]))
        let store = ClaudeCodeConnectionStore(database: db, fetcher: fetcher)

        await store.fetchNow()

        guard case .connected(let lastFetchAt) = store.state else {
            Issue.record("Expected .connected, got \(store.state)")
            return
        }
        #expect(lastFetchAt != nil)
    }

    @Test("fetchNow 401 transitions to authExpired")
    func fetchNow401Transitions() async throws {
        let db = try SeshctlDatabase.temporary()
        let fetcher = StubFetcher(result: .failure(RemoteClaudeCodeError.needsReauth))
        let store = ClaudeCodeConnectionStore(database: db, fetcher: fetcher)

        await store.fetchNow()

        #expect(store.state == .authExpired)
    }

    @Test("fetchNow transient error transitions to transientError")
    func fetchNowTransientError() async throws {
        let db = try SeshctlDatabase.temporary()
        let fetcher = StubFetcher(result: .failure(RemoteClaudeCodeError.http(500)))
        let store = ClaudeCodeConnectionStore(database: db, fetcher: fetcher)

        await store.fetchNow()

        guard case .transientError = store.state else {
            Issue.record("Expected .transientError, got \(store.state)")
            return
        }
    }

    @Test("hasClaudeConnection reflects state")
    func hasClaudeConnectionPredicate() async throws {
        let db = try SeshctlDatabase.temporary()
        let fetcher = StubFetcher(result: .success([]))

        let notConnected = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .notConnected
        )
        #expect(notConnected.hasClaudeConnection == false)

        let connecting = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .connecting
        )
        #expect(connecting.hasClaudeConnection == false)

        let connected = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .connected(lastFetchAt: nil)
        )
        #expect(connected.hasClaudeConnection == true)

        let authExpired = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .authExpired
        )
        #expect(authExpired.hasClaudeConnection == true)

        let transientError = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .transientError("any")
        )
        #expect(transientError.hasClaudeConnection == true)

        // Second transient-error value — confirms the associated string is
        // irrelevant to the predicate; any `.transientError` is cloud-live.
        let transientOther = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .transientError("network lost")
        )
        #expect(transientOther.hasClaudeConnection == true)
    }

    @Test("disconnect clears DB and transitions to notConnected")
    func disconnectClearsEverything() async throws {
        let db = try SeshctlDatabase.temporary()
        let seeded = makeRemoteSession()
        try db.upsertRemoteClaudeCodeSessions([seeded])
        #expect(try db.listRemoteClaudeCodeSessions().count == 1)

        let fetcher = StubFetcher(result: .success([]))
        let store = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .connected(lastFetchAt: Date())
        )

        await store.disconnect()

        #expect(store.state == .notConnected)
        #expect(try db.listRemoteClaudeCodeSessions().isEmpty)
    }
}

// MARK: - Remote away-summary cache + dispatch

@Suite("ClaudeCodeConnectionStore.remoteAwaySummariesById")
@MainActor
struct ClaudeCodeConnectionStoreAwaySummaryTests {

    @Test("successful events fetch populates the map (and absent entries don't materialize)")
    func successfulFetchPopulatesMap() async throws {
        let db = try SeshctlDatabase.temporary()
        let session1 = makeRemoteSession(id: "cse_session_one")
        let session2 = makeRemoteSession(id: "cse_session_two")
        let fetcher = StubFetcher(result: .success([session1, session2]))
        await fetcher.setAssistantText(.success("Hi"), forSessionID: session1.id)
        // session2 has no entry — stub returns nil.

        let store = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .connected(lastFetchAt: nil)
        )

        await store.fetchNow()
        await store.awaitPendingAwaySummaryFetches()

        #expect(store.remoteAwaySummariesById[session1.id] == "Hi")
        #expect(store.remoteAwaySummariesById[session2.id] == nil)
    }

    @Test("no re-dispatch when cache holds current lastEventAt")
    func noRedispatchOnCacheHit() async throws {
        let db = try SeshctlDatabase.temporary()
        let session1 = makeRemoteSession(id: "cse_cache_hit")
        let fetcher = StubFetcher(result: .success([session1]))
        await fetcher.setAssistantText(.success("first"), forSessionID: session1.id)

        let store = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .connected(lastFetchAt: nil)
        )

        await store.fetchNow()
        await store.awaitPendingAwaySummaryFetches()
        await store.fetchNow()
        await store.awaitPendingAwaySummaryFetches()

        let calls = await fetcher.assistantTextCallCount(for: session1.id)
        #expect(calls == 1)
    }

    @Test("advancing lastEventAt re-dispatches an events fetch")
    func advancingLastEventAtRedispatches() async throws {
        let db = try SeshctlDatabase.temporary()
        let firstSeenAt = Date(timeIntervalSince1970: 1_700_000_000)
        let laterSeenAt = Date(timeIntervalSince1970: 1_700_000_999)
        let id = "cse_advancing"
        let initialSession = makeRemoteSession(id: id, lastEventAt: firstSeenAt)
        let advancedSession = makeRemoteSession(id: id, lastEventAt: laterSeenAt)

        let fetcher = StubFetcher(result: .success([initialSession]))
        await fetcher.setAssistantText(.success("first"), forSessionID: id)

        let store = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .connected(lastFetchAt: nil)
        )

        await store.fetchNow()
        await store.awaitPendingAwaySummaryFetches()

        await fetcher.setRefreshResult(.success([advancedSession]))
        await fetcher.setAssistantText(.success("second"), forSessionID: id)

        await store.fetchNow()
        await store.awaitPendingAwaySummaryFetches()

        let calls = await fetcher.assistantTextCallCount(for: id)
        #expect(calls == 2)
        #expect(store.remoteAwaySummariesById[id] == "second")
    }

    @Test("failed events fetch caches nil; does not retry on same lastEventAt")
    func failedFetchCachesNilAndStopsRetry() async throws {
        let db = try SeshctlDatabase.temporary()
        let session1 = makeRemoteSession(id: "cse_failing")
        let fetcher = StubFetcher(result: .success([session1]))
        await fetcher.setAssistantText(
            .failure(RemoteClaudeCodeError.http(500)),
            forSessionID: session1.id
        )

        let store = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .connected(lastFetchAt: nil)
        )

        await store.fetchNow()
        await store.awaitPendingAwaySummaryFetches()

        #expect(store.remoteAwaySummariesById[session1.id] == nil)

        await store.fetchNow()
        await store.awaitPendingAwaySummaryFetches()

        let calls = await fetcher.assistantTextCallCount(for: session1.id)
        #expect(calls == 1)
    }

    @Test("prune drops cache entries for sessions absent from latest list")
    func pruneDropsAbsentSessions() async throws {
        let db = try SeshctlDatabase.temporary()
        let session1 = makeRemoteSession(id: "cse_prune_a")
        let session2 = makeRemoteSession(id: "cse_prune_b")
        let fetcher = StubFetcher(result: .success([session1, session2]))
        await fetcher.setAssistantText(.success("text"), forSessionID: session1.id)
        await fetcher.setAssistantText(.success("text"), forSessionID: session2.id)

        let store = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .connected(lastFetchAt: nil)
        )

        await store.fetchNow()
        await store.awaitPendingAwaySummaryFetches()
        #expect(store.remoteAwaySummariesById[session1.id] == "text")
        #expect(store.remoteAwaySummariesById[session2.id] == "text")

        // Drop session1 from the list — prune should evict it.
        await fetcher.setRefreshResult(.success([session2]))
        await store.fetchNow()
        await store.awaitPendingAwaySummaryFetches()

        #expect(store.remoteAwaySummariesById[session1.id] == nil)
        #expect(store.remoteAwaySummariesById[session2.id] == "text")
    }

    @Test("disconnect clears the cache and the map")
    func disconnectClearsAwaySummaryState() async throws {
        let db = try SeshctlDatabase.temporary()
        let session1 = makeRemoteSession(id: "cse_disconnect_clear")
        let fetcher = StubFetcher(result: .success([session1]))
        await fetcher.setAssistantText(.success("hello"), forSessionID: session1.id)

        let store = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .connected(lastFetchAt: nil)
        )

        await store.fetchNow()
        await store.awaitPendingAwaySummaryFetches()
        #expect(store.remoteAwaySummariesById[session1.id] == "hello")

        await store.disconnect()

        #expect(store.remoteAwaySummariesById.isEmpty)

        // Indirectly verify that the private `remoteAwaySummaryCache` was also
        // cleared: a follow-up `fetchNow()` from a reconnected state with the
        // same lastEventAt MUST dispatch a fresh fetch (call count goes 1→2).
        // If the cache hadn't been cleared, the cache-hit guard would suppress
        // the dispatch and the count would stay at 1.
        await fetcher.setRefreshResult(.success([session1]))
        // Re-enter `.connected` via the public sign-in success path equivalent:
        // disconnect transitioned us to `.notConnected`, so the next fetchNow
        // would succeed and land us back in `.connected` automatically — and
        // the dispatched task's `hasClaudeConnection` guard fires AFTER the
        // state transition, so the result will populate the map.
        await store.fetchNow()
        await store.awaitPendingAwaySummaryFetches()
        let calls = await fetcher.assistantTextCallCount(for: session1.id)
        #expect(calls == 2)
        #expect(store.remoteAwaySummariesById[session1.id] == "hello")
    }

    @Test("disconnect cancels in-flight fetches so they don't repopulate the map")
    func disconnectCancelsInFlightFetches() async throws {
        let db = try SeshctlDatabase.temporary()
        let session1 = makeRemoteSession(id: "cse_inflight_cancel")
        let fetcher = StubFetcher(result: .success([session1]))
        await fetcher.setAssistantText(.success("late"), forSessionID: session1.id)
        await fetcher.setAssistantTextDelay(nanoseconds: 100_000_000) // 100ms

        let store = ClaudeCodeConnectionStore(
            database: db,
            fetcher: fetcher,
            initialState: .connected(lastFetchAt: nil)
        )

        await store.fetchNow()
        // Don't await pending fetches yet — disconnect mid-flight.
        await store.disconnect()
        await store.awaitPendingAwaySummaryFetches()

        // Either the task cancelled cleanly, or its hasClaudeConnection
        // guard fired after the await — in both cases the map stays empty.
        #expect(store.remoteAwaySummariesById.isEmpty)
    }
}

