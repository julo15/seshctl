// RecallService — the static-API façade callers use to run semantic recall
// searches. Backed by `RecallStack`, an actor that lazily wires up
// `EmbeddingService` + `VectorStore` + `Indexer` + `Search` on first use.
//
// Public surface (preserved from the pre-Phase-6 stub so the UI doesn't
// ripple):
//   - `RecallService.search(query:limit:onIndexing:)` — static async, throws.
//   - `RecallService.isAvailable()` — static; always `true` for the native
//     implementation (no external binary to probe).
//
// New: `RecallService.configure(database:)` must be called exactly once at
// app startup, after the `SeshctlDatabase` is constructed. `AppDelegate.
// applicationDidFinishLaunching` is the canonical call site. Calling
// `search()` without first calling `configure()` throws
// `RecallError.searchFailed(...)`.
//
// Concurrency: the shared stack is built lazily inside a `Task` whose
// completion is awaited by every concurrent caller of `sharedStack()`. The
// `NSLock` only guards the read/write of the shared-state slots; the actual
// stack construction runs outside the lock.

import Foundation
import SeshctlCore

// MARK: - Public response type.

public struct RecallSearchResponse: Sendable {
    public let results: [RecallResult]
    public let indexingCount: Int?

    public init(results: [RecallResult], indexingCount: Int?) {
        self.results = results
        self.indexingCount = indexingCount
    }
}

// MARK: - Service façade.

public struct RecallService: Sendable {

    // MARK: - Lifecycle.

    /// Wire RecallService to the seshctl database. MUST be called exactly
    /// once at startup, before any `search()` invocation. AppDelegate calls
    /// this immediately after constructing `SeshctlDatabase`.
    ///
    /// Calling `configure` more than once is a no-op for the database slot
    /// (only the first call's database is used). The shared stack is built
    /// lazily on the first `search()` call and holds the database by
    /// reference for the lifetime of the process.
    ///
    /// Tests use `configureForTesting(database:adapters:)` paired with
    /// `_resetForTests()` instead.
    public static func configure(database: SeshctlDatabase) {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        // First-call-wins: subsequent invocations are ignored so the
        // already-constructed stack's database reference stays coherent.
        if sharedDatabase == nil {
            sharedDatabase = database
        }
    }

    /// The native implementation has no external binary to probe — the
    /// stack is part of the bundled `.app`. Always `true`.
    public static func isAvailable() -> Bool {
        return true
    }

    /// Run a semantic recall search.
    ///
    /// - Empty/whitespace queries short-circuit to an empty result set
    ///   without touching the index.
    /// - First call lazily constructs the stack (loads the CoreML model,
    ///   opens the vector store, instantiates adapters). Subsequent calls
    ///   reuse the same actor.
    /// - Concurrent first calls coalesce on a single in-flight construction
    ///   `Task` — only one model load happens per process.
    public static func search(
        query: String,
        limit: Int = 10,
        onIndexing: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> RecallSearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RecallSearchResponse(results: [], indexingCount: nil)
        }

        let stack = try await sharedStack()
        return try await stack.search(query: trimmed, limit: limit, onIndexing: onIndexing)
    }

    // MARK: - Shared-state plumbing.

    // `NSLock` (not an actor) so the synchronous `configure(_:)` entry
    // point and the synchronous slot-read inside `sharedStack()` don't have
    // to be `async`. `nonisolated(unsafe)` is required under Swift 6 strict
    // concurrency because the slots are mutated through a Sendable struct;
    // the `NSLock` provides the actual mutual exclusion.
    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var sharedDatabase: SeshctlDatabase?
    nonisolated(unsafe) private static var sharedStackTask: Task<RecallStack, Error>?
    nonisolated(unsafe) private static var sharedAdaptersOverride: [any Adapter]?

    /// Internal accessor for `RecallStack.build()` to read the configured
    /// database under the lock. Not part of the public API.
    static func sharedDatabaseAccessor() -> SeshctlDatabase? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return sharedDatabase
    }

    /// Internal accessor for `RecallStack.build()` to read the
    /// test-injected adapters override, if any. Production code paths see
    /// `nil` and fall through to `AdapterRegistry.defaultAdapters()`.
    static func sharedAdaptersOverrideAccessor() -> [any Adapter]? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return sharedAdaptersOverride
    }

    /// Return the shared stack, constructing it on first call. Concurrent
    /// callers share a single in-flight `Task` so the model only loads once.
    private static func sharedStack() async throws -> RecallStack {
        let task = getOrCreateStackTask()
        do {
            return try await task.value
        } catch {
            // On build failure, clear the cached Task so the next caller
            // gets a fresh attempt instead of replaying the same error
            // (e.g. user installs the model file mid-session in Phase 7).
            clearStackTaskIfCurrent()
            throw error
        }
    }

    /// Synchronous slot read/write helpers — Swift 6 forbids `NSLock.lock()`
    /// from `async` contexts, so all lock-guarded mutations live in
    /// non-async helpers that the async code calls.
    private static func getOrCreateStackTask() -> Task<RecallStack, Error> {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = sharedStackTask {
            return existing
        }
        let task = Task<RecallStack, Error> {
            try await RecallStack.build()
        }
        sharedStackTask = task
        return task
    }

    /// Drop the cached construction Task. Called after a failed build so
    /// the next `search()` call retries from scratch. We always clear (we
    /// can't compare `Task` values for identity — `Task` is a struct — and
    /// the only writer is `getOrCreateStackTask`, so a clear after failure
    /// is correct even under racing callers: the next call rebuilds).
    private static func clearStackTaskIfCurrent() {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        sharedStackTask = nil
    }

    // MARK: - Test seam.

    /// Reset the shared state. Test-only — `RecallService` holds process-wide
    /// state so tests need to clear it between runs. Not for production use.
    @_spi(Testing)
    public static func _resetForTests() {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        sharedDatabase = nil
        sharedStackTask = nil
        sharedAdaptersOverride = nil
    }

    /// Test-only entry point: configure with both the database AND an
    /// explicit adapter list. Bypasses `AdapterRegistry.defaultAdapters()`
    /// so tests can inject mock adapters that DON'T walk the developer's
    /// real `~/.claude/projects`, `~/.codex`, `~/.gemini` directories.
    ///
    /// Always pair with `_resetForTests()` between test cases.
    @_spi(Testing)
    public static func configureForTesting(
        database: SeshctlDatabase,
        adapters: [any Adapter]
    ) {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        sharedDatabase = database
        sharedAdaptersOverride = adapters
        // Clear any prior stack so the next search rebuilds against the
        // injected adapters.
        sharedStackTask = nil
    }
}

// MARK: - Backing actor.

/// Owns the live recall services. One instance per process, lazily built by
/// `RecallService.sharedStack()`. Sealed (file-private constructor) so the
/// only construction path is `RecallStack.build()`.
final actor RecallStack {
    private let database: SeshctlDatabase
    private let vectorStore: VectorStore
    private let embedder: EmbeddingService
    private let indexer: Indexer

    private init(
        database: SeshctlDatabase,
        vectorStore: VectorStore,
        embedder: EmbeddingService,
        indexer: Indexer
    ) {
        self.database = database
        self.vectorStore = vectorStore
        self.embedder = embedder
        self.indexer = indexer
    }

    /// Build the stack. Reads the database configured via
    /// `RecallService.configure(database:)` — throws
    /// `RecallError.searchFailed(...)` if `configure()` was never called.
    /// The `EmbeddingService()` init also throws (model resource not found)
    /// until Phase 7 ships the bundled `.mlpackage`.
    ///
    /// In test contexts that called
    /// `RecallService.configureForTesting(database:adapters:)`, the
    /// injected adapter list replaces `AdapterRegistry.defaultAdapters()`
    /// so tests don't walk the developer's real transcript directories.
    static func build() async throws -> RecallStack {
        guard let database = RecallService.sharedDatabaseAccessor() else {
            throw RecallError.searchFailed(
                "RecallService.configure(database:) was never called — "
                + "call from AppDelegate at startup"
            )
        }
        let vectorStore = VectorStore(database: database)
        let embedder = try await EmbeddingService()
        let adapters = RecallService.sharedAdaptersOverrideAccessor()
            ?? AdapterRegistry.defaultAdapters()
        let indexer = Indexer(
            store: vectorStore,
            embedder: embedder,
            adapters: adapters
        )
        return RecallStack(
            database: database,
            vectorStore: vectorStore,
            embedder: embedder,
            indexer: indexer
        )
    }

    /// End-to-end search: incremental index refresh → query encode → load
    /// stored vectors → top-K with session-level dedup → hydrate `RecallResult`.
    func search(
        query: String,
        limit: Int,
        onIndexing: (@Sendable (Int, Int) -> Void)?
    ) async throws -> RecallSearchResponse {
        // 1. Bring the index up to date. Progress flows straight through.
        try await indexer.refresh(batchSize: 64, onProgress: onIndexing)
        let totalIndexed = try await vectorStore.entryCount()

        // 2. Encode the query. `encode` always returns one vector per input.
        let queryVecs = try await embedder.encode([query], batchSize: 1, onProgress: nil)
        guard let queryVec = queryVecs.first else {
            return RecallSearchResponse(results: [], indexingCount: totalIndexed)
        }

        // 3. Load every stored embedding into memory. At ~1.5KB per vector
        //    and a realistic ceiling of ~10k entries, this is ~15MB — fine
        //    for an interactive search loop. Future-phase optimization (if
        //    needed): persistent kNN index instead of brute-force scan.
        let (ids, vectors) = try await vectorStore.loadAllEmbeddings()
        if ids.isEmpty {
            return RecallSearchResponse(results: [], indexingCount: totalIndexed)
        }

        // 4. Hydrate entries so we can both build session-level dedup keys
        //    and emit `RecallResult`s without a second DB round-trip.
        let allEntries = try await vectorStore.entries(forIDs: ids)
        var idToEntry: [Int64: HistoryEntry] = [:]
        idToEntry.reserveCapacity(allEntries.count)
        for entry in allEntries {
            if let entryID = entry.id {
                idToEntry[entryID] = entry
            }
        }
        let dedupKeys: [String] = ids.map { id in
            guard let e = idToEntry[id] else { return "__missing__\(id)" }
            return "\(e.agent)|\(e.sessionID)"
        }

        // 5. Top-K with (agent, session_id) dedup. Mirrors
        //    recall/search.py's posture of one row per session.
        let hits = Search.topK(
            queryVector: queryVec,
            storedIDs: ids,
            storedVectors: vectors,
            k: limit,
            dedupKeys: dedupKeys
        )

        // 6. Map to RecallResult. Skip any hit whose entry vanished between
        //    the embedding-load and the entry-hydrate (shouldn't happen —
        //    same DB read transaction conceptually — but be defensive).
        let results: [RecallResult] = hits.compactMap { hit in
            guard let entry = idToEntry[hit.id] else { return nil }
            return RecallResult(
                agent: entry.agent,
                role: entry.role,
                sessionId: entry.sessionID,
                project: entry.project,
                timestamp: entry.timestamp,
                score: Double(hit.score),
                resumeCmd: Self.resumeCommand(for: entry),
                text: entry.text
            )
        }

        return RecallSearchResponse(results: results, indexingCount: totalIndexed)
    }

    /// Mirror the Python pipeline's per-agent resume command. Exhaustive
    /// over `SessionTool` so the compiler flags any new tool we add to
    /// `SessionTool` without also wiring it here (see AGENTS.md "Adding
    /// an LLM Tool"). Unknown agents — strings persisted in the index
    /// that don't map to a `SessionTool` — return an empty string;
    /// callers (the UI) treat empty `resumeCmd` as "no resume affordance".
    private static func resumeCommand(for entry: HistoryEntry) -> String {
        guard let tool = SessionTool(rawValue: entry.agent) else {
            // Unknown agent persisted in the index — should never happen
            // for entries written by our own adapters. Empty string
            // matches the pre-refactor fallback.
            return ""
        }
        switch tool {
        case .claude:
            return "claude --resume \(entry.sessionID)"
        case .codex:
            return "codex --resume \(entry.sessionID)"
        case .gemini:
            return "gemini"
        case .cursor:
            // Cursor sessions can be resumed via the cursor:// URI
            // handler (see
            // Sources/SeshctlUI/TerminalController.focusViaURIHandler),
            // not via a CLI. Return empty so the recall result row
            // doesn't show a misleading resume command.
            return ""
        }
    }
}
