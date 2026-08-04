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
    nonisolated(unsafe) private static var sharedEmbedderOverride: (any Embedder)?

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

    /// Internal accessor for `RecallStack.build()` to read the
    /// test-injected embedder override, if any. Production code paths see
    /// `nil` and fall through to `try await EmbeddingService()` (which
    /// loads the bundled CoreML model). Test paths inject a `MockEmbedder`
    /// so they don't depend on CoreML wall-clock or the bundled resources.
    static func sharedEmbedderOverrideAccessor() -> (any Embedder)? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return sharedEmbedderOverride
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
        sharedEmbedderOverride = nil
    }

    /// Test-only entry point: configure with the database, an explicit
    /// adapter list, and optionally an explicit embedder. Bypasses
    /// `AdapterRegistry.defaultAdapters()` so tests can inject mock
    /// adapters that DON'T walk the developer's real `~/.claude/projects`,
    /// `~/.codex`, `~/.gemini` directories. Passing a non-nil `embedder`
    /// (typically a `MockEmbedder`) also bypasses the bundled CoreML model
    /// load so timing-sensitive tests don't depend on CoreML wall-clock.
    ///
    /// Always pair with `_resetForTests()` between test cases.
    @_spi(Testing)
    public static func configureForTesting(
        database: SeshctlDatabase,
        adapters: [any Adapter],
        embedder: (any Embedder)? = nil
    ) {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        sharedDatabase = database
        sharedAdaptersOverride = adapters
        sharedEmbedderOverride = embedder
        // Clear any prior stack so the next search rebuilds against the
        // injected adapters + embedder.
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
    private let embedder: any Embedder
    private let indexer: Indexer

    // MARK: - Background indexing state.
    //
    // Indexing is a detached, long-lived task that survives across the
    // lifecycle of individual `search()` calls. Multiple concurrent searches
    // (typical UX: each keystroke kicks off a new search and cancels the
    // prior one) share a single in-flight indexing pass — the await on
    // `indexingTask.value` is cancellable from each caller's perspective,
    // but the detached task itself is NOT canceled, so canceling a search
    // doesn't roll back indexing progress.

    /// The currently-running indexing task, or nil if no refresh is in
    /// flight. Set when the first concurrent caller of `ensureIndexingComplete`
    /// kicks off a refresh; cleared by the detached task itself on
    /// completion or error so the next caller starts fresh.
    private var indexingTask: Task<Void, Error>?

    /// Active progress subscribers — one per in-flight `search()` call that
    /// supplied an `onIndexing` callback. The detached indexing task
    /// broadcasts to all of them. Searches subscribe on entry and remove
    /// themselves on exit (via the `defer` in `search()`).
    private var indexingSubscribers: [UUID: @Sendable (Int, Int) -> Void] = [:]

    /// The last (done, total) pair broadcast by the indexing task. Cached so
    /// a newly-arrived search that subscribes mid-flight can immediately
    /// receive the current progress instead of waiting for the next batch.
    private var lastIndexingProgress: (done: Int, total: Int)?

    /// Monotonically-increasing tag identifying the current indexing pass.
    /// `runDetachedIndexing` increments this before starting each refresh and
    /// captures the value for use in the progress callback. The broadcast
    /// helper drops events whose `passID` doesn't match the current value —
    /// kills the cross-pass leak where a late-arriving progress Task from
    /// Run 1 lands on the actor AFTER Run 2 has already cleared the seed
    /// and re-poisons `lastIndexingProgress`. Without this, Run 2's chunks
    /// look "out-of-order" to the monotonic-done guard and get dropped.
    private var indexingPassID: Int = 0

    private init(
        database: SeshctlDatabase,
        vectorStore: VectorStore,
        embedder: any Embedder,
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
    /// The `EmbeddingService()` init throws (model resource not found) if
    /// the bundled `.mlpackage` is missing.
    ///
    /// In test contexts that called
    /// `RecallService.configureForTesting(database:adapters:embedder:)`,
    /// the injected adapter list replaces `AdapterRegistry.defaultAdapters()`
    /// and a non-nil injected embedder replaces the real
    /// `EmbeddingService` — so tests don't walk the developer's real
    /// transcript directories nor pay CoreML wall-clock cost.
    static func build() async throws -> RecallStack {
        guard let database = RecallService.sharedDatabaseAccessor() else {
            throw RecallError.searchFailed(
                "RecallService.configure(database:) was never called — "
                + "call from AppDelegate at startup"
            )
        }
        let vectorStore = VectorStore(database: database)
        let embedder: any Embedder
        if let injected = RecallService.sharedEmbedderOverrideAccessor() {
            embedder = injected
        } else {
            embedder = try await EmbeddingService()
        }
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
    ///
    /// Indexing runs as a detached background task — if you cancel a search
    /// (UI typically does this on each keystroke), the indexing keeps
    /// running. The next search joins the same task instead of restarting.
    func search(
        query: String,
        limit: Int,
        onIndexing: (@Sendable (Int, Int) -> Void)?
    ) async throws -> RecallSearchResponse {
        // 1. Subscribe for progress and seed the caller with the latest
        //    known value so they don't see 0/N when joining an in-flight
        //    refresh that's already at 5000/8000.
        let subID = onIndexing.map { subscribeIndexingProgress($0) }
        if let onIndexing, let last = lastIndexingProgress {
            onIndexing(last.done, last.total)
        }
        defer {
            if let subID {
                // Unsubscribe synchronously — we're on the actor, no hop needed.
                indexingSubscribers.removeValue(forKey: subID)
            }
        }

        // 2. Bring the index up to date (or join an in-flight refresh).
        //    The await is cancellable per caller; the detached refresh
        //    survives caller cancellation.
        try await ensureIndexingComplete()
        let totalIndexed = try await vectorStore.entryCount()

        // 3. Encode the query. `encode` always returns one vector per input.
        let queryVecs = try await embedder.encode([query], batchSize: 1, onProgress: nil)
        guard let queryVec = queryVecs.first else {
            return RecallSearchResponse(results: [], indexingCount: totalIndexed)
        }

        // 4. Load every stored embedding into memory. At ~1.5KB per vector
        //    and a realistic ceiling of ~10k entries, this is ~15MB — fine
        //    for an interactive search loop. Future-phase optimization (if
        //    needed): persistent kNN index instead of brute-force scan.
        let (ids, vectors) = try await vectorStore.loadAllEmbeddings()
        if ids.isEmpty {
            return RecallSearchResponse(results: [], indexingCount: totalIndexed)
        }

        // 5. Hydrate entries so we can both build session-level dedup keys
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

        // 6. Top-K with (agent, session_id) dedup. Mirrors
        //    recall/search.py's posture of one row per session.
        let hits = Search.topK(
            queryVector: queryVec,
            storedIDs: ids,
            storedVectors: vectors,
            k: limit,
            dedupKeys: dedupKeys
        )

        // 7. Map to RecallResult. Skip any hit whose entry vanished between
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
        case .pi:
            // `--session` takes a full path or a partial UUID; the session id
            // is the UUID Pi embeds in the transcript filename.
            return "pi --session \(entry.sessionID)"
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

    // MARK: - Background indexing coordination.

    /// Trigger indexing (or join an in-flight pass) and wait for it to
    /// complete. The await is cancellable per the caller's Task; the
    /// underlying detached refresh is NOT — canceling a search leaves the
    /// indexing running so the next search joins it instead of restarting.
    private func ensureIndexingComplete() async throws {
        if let existing = indexingTask {
            // Join the in-flight refresh. Caller cancel aborts only this
            // await; the detached task keeps running.
            try await existing.value
            return
        }
        // Start a new detached refresh. `Task.detached` is the key — it
        // breaks the parent-task cancellation chain so caller cancellation
        // doesn't propagate into `indexer.refresh`. The slot-and-clear
        // pattern coalesces concurrent ensure calls onto the same task.
        //
        // Strong `self` capture is safe: the detached Task itself retains
        // `self` for the lifetime of the closure body — independent of any
        // external hold on the Task handle. The `indexingTask` slot is
        // just a coalescing handle for concurrent `ensureIndexingComplete`
        // callers; clearing it from `clearIndexingTask` (which is called
        // from inside the body) doesn't shorten the body's `self` lifetime.
        let task = Task<Void, Error>.detached { [self] in
            do {
                try await self.runDetachedIndexing()
                await self.clearIndexingTask()
            } catch {
                await self.clearIndexingTask()
                throw error
            }
        }
        indexingTask = task
        try await task.value
    }

    /// The body of the detached indexing task. Calls `indexer.refresh`
    /// with a progress callback that broadcasts back to the actor's
    /// subscriber list. Runs as a non-isolated context so the `Task` slot
    /// in `ensureIndexingComplete` is the only escape hatch from caller
    /// cancellation.
    private func runDetachedIndexing() async throws {
        // Tag this pass + clear any prior pass's final value so a new
        // search joining the fresh refresh BEFORE the first chunk fires
        // doesn't see a stale seed (e.g. "8000/8000" left over from the
        // last completed run). The passID tag also defends against
        // late-arriving progress Tasks from the prior pass — see
        // `broadcastIndexingProgress`.
        indexingPassID += 1
        let myPassID = indexingPassID
        lastIndexingProgress = nil
        try await indexer.refresh(batchSize: 64, onProgress: { [weak self] done, total in
            Task { [weak self] in
                await self?.broadcastIndexingProgress(
                    passID: myPassID,
                    done: done,
                    total: total
                )
            }
        })
    }

    /// Add a progress subscriber. Returns the id to use for unsubscribe.
    /// Searches add themselves on entry and remove on exit (via `defer`).
    private func subscribeIndexingProgress(
        _ callback: @Sendable @escaping (Int, Int) -> Void
    ) -> UUID {
        let id = UUID()
        indexingSubscribers[id] = callback
        return id
    }

    /// Update `lastIndexingProgress` and forward to every active subscriber.
    /// Called from the detached indexing task via an actor hop.
    ///
    /// Drops two classes of stale events:
    ///
    /// 1. **Cross-pass leakage** — a progress Task spawned by Run 1 that
    ///    lands on the actor AFTER Run 2 has started clears `passID` will
    ///    be discarded by the passID guard. Without this, Run 2's first
    ///    chunks look "out-of-order" to the monotonic-done guard and the
    ///    UI bar gets stuck at Run 1's final value.
    ///
    /// 2. **Intra-pass FIFO violation** — each per-chunk progress event
    ///    spawns its own Task to hop back to the actor, and the actor's
    ///    executor may schedule them out of FIFO order within a single
    ///    pass. The monotonic-done guard discards the stale event so
    ///    `lastIndexingProgress` never goes backward and the UI never
    ///    jitters.
    ///
    /// Subscribers may occasionally miss an intermediate value but the
    /// FINAL `(done == total)` always lands (it's never dropped by either
    /// guard — `prev.done > done` is false at the terminal value).
    private func broadcastIndexingProgress(passID: Int, done: Int, total: Int) {
        guard passID == indexingPassID else { return }
        if let prev = lastIndexingProgress, prev.done > done, prev.total == total {
            return
        }
        lastIndexingProgress = (done, total)
        for callback in indexingSubscribers.values {
            callback(done, total)
        }
    }

    /// Clear the indexing-task slot. The next caller of
    /// `ensureIndexingComplete` will start a fresh refresh (cheap when
    /// cursors are already caught up). Called from the detached task
    /// itself on completion or error.
    ///
    /// Safe because (a) only the detached task itself calls this, and
    /// (b) `indexingTask` is only ever assigned from nil → new value
    /// (the `if let existing` guard in `ensureIndexingComplete` returns
    /// before reaching the assignment when the slot is non-nil), so the
    /// clear never accidentally drops a newer task.
    private func clearIndexingTask() {
        indexingTask = nil
    }
}
