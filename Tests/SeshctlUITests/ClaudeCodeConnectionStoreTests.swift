import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

/// Stub `RemoteClaudeCodeFetching` for the instance-level store tests. Actor
/// isolation keeps the stored `Result` thread-safe; the payload is lazily
/// unwrapped in `refresh()`, so the same stub can serve many calls.
private actor StubFetcher: RemoteClaudeCodeFetching {
    private var result: Result<[RemoteClaudeCodeSession], Error>

    init(result: Result<[RemoteClaudeCodeSession], Error>) {
        self.result = result
    }

    func refresh() async throws -> [RemoteClaudeCodeSession] {
        try result.get()
    }

    func fetchLatestAssistantText(sessionId: String) async throws -> String? {
        // Existing tests don't exercise this; later step's tests will use a
        // richer stub with per-id result injection.
        nil
    }
}

private func makeRemoteSession(id: String = "cse_test_\(UUID().uuidString)") -> RemoteClaudeCodeSession {
    RemoteClaudeCodeSession(
        id: id,
        title: "Test session",
        model: "claude-opus-4-7",
        repoUrl: "https://github.com/julo15/example",
        branches: ["main"],
        status: "active",
        workerStatus: "idle",
        connectionStatus: "connected",
        lastEventAt: Date(),
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
