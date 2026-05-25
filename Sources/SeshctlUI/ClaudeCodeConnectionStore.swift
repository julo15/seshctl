import Foundation
import SwiftUI
import WebKit

import SeshctlCore

// MARK: - Fetcher protocol

/// Testability seam for `ClaudeCodeConnectionStore.fetchNow()`. The production
/// conformance is `RemoteClaudeCodeFetcher`; tests supply a stub so they don't
/// spin up a real `URLSession` or WebKit cookie store.
public protocol RemoteClaudeCodeFetching: Sendable {
    func refresh() async throws -> [RemoteClaudeCodeSession]
    func fetchLatestAssistantText(sessionId: String) async throws -> String?
}

extension RemoteClaudeCodeFetcher: RemoteClaudeCodeFetching {}

// MARK: - Connection store

/// Owns the Claude Code (cloud) connection state machine. Backs both the
/// settings popover and the (future) sign-in banner.
///
/// States:
/// - `.notConnected` — never connected, or user explicitly disconnected.
/// - `.connecting` — sign-in sheet is open.
/// - `.connected(lastFetchAt:)` — has cookies; may or may not have fetched.
/// - `.authExpired` — 401 on last fetch; cached rows stay visible.
/// - `.transientError(_)` — 5xx / network / decode; cached rows unchanged.
///
/// Transitions are driven by three entry points:
/// - `presentSignIn()` — opens the sheet; on success triggers `fetchNow()`.
/// - `fetchNow()` — issues a refresh, maps the result to the next state.
/// - `disconnect()` — clears cookies + cache, transitions to `.notConnected`.
@MainActor
public final class ClaudeCodeConnectionStore: ObservableObject {
    public enum State: Equatable {
        case notConnected
        case connecting
        case connected(lastFetchAt: Date?)
        case authExpired
        case transientError(String)
    }

    @Published public private(set) var state: State

    // MARK: - Derived state

    /// True when the user has an active or previously-active claude.ai
    /// connection. UI should show cloud affordances (the bridged marker and the
    /// header's "N remote" counter) only when this is true. Intentionally
    /// includes `.authExpired` and `.transientError` — the user is still
    /// conceptually connected; they just need to reauth or retry.
    ///
    /// `.connecting` returns false because the sign-in sheet is modal — it
    /// blocks the popover UI for the duration, so any brief chrome drop
    /// during reconnect is not user-visible. If a future UI surface shows
    /// cloud chrome while the sheet is up (e.g. a persistent dock badge),
    /// reconsider this — the predicate may need a "prior state was connected"
    /// carve-out or callers may need to inspect `state` directly.
    public var hasClaudeConnection: Bool {
        switch state {
        case .notConnected, .connecting: return false
        case .connected, .authExpired, .transientError: return true
        }
    }

    private let database: SeshctlDatabase
    private let fetcher: RemoteClaudeCodeFetching
    private var activeSheet: ClaudeCodeSignInSheet?
    private var periodicTimer: Timer?

    /// Cache of `(lastEventAt, parsed assistant summary)` per remote session id.
    /// Hit when the list endpoint reports the same `lastEventAt` we already
    /// fetched against; miss when it advanced or the entry is absent. A nil
    /// `summary` is a valid hit — means we already tried for THIS lastEventAt
    /// and got nothing (no assistant event, or the fetch failed). We don't
    /// retry until `lastEventAt` advances, so failures don't loop.
    private var remoteAwaySummaryCache: [String: (lastEventAt: Date, summary: String?)] = [:]

    /// Pairs a dispatched fetch task with a per-dispatch UUID so the Task's
    /// `defer` cleanup can identity-check before wiping the dict entry. Without
    /// the UUID, a slow Task A that finally returns after `disconnect()` +
    /// reconnect + a fresh Task B dispatch under the same session id would
    /// erase B's entry — making the next `fetchNow()` re-dispatch a duplicate.
    private struct PendingAwaySummaryFetch {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// In-flight `fetchLatestAssistantText` tasks keyed by session id. Used
    /// both as the duplicate-dispatch guard AND as the awaitable handle so
    /// tests can deterministically wait for pending fetches via
    /// `awaitPendingAwaySummaryFetches()`. Entries remove themselves via
    /// `defer` inside the Task body — but only if the slot still holds the
    /// same dispatch UUID (see `PendingAwaySummaryFetch`).
    private var awaySummaryFetchTasks: [String: PendingAwaySummaryFetch] = [:]

    /// Published map of `session id → most recent assistant text` for pure-
    /// remote rows. Sessions absent from this map fall through to the row's
    /// existing `.reply(title)` preview. Computed lazily by per-session
    /// events fetches dispatched from `fetchNow()`.
    @Published public private(set) var remoteAwaySummariesById: [String: String] = [:]

    public init(
        database: SeshctlDatabase,
        fetcher: RemoteClaudeCodeFetching,
        initialState: State = .notConnected
    ) {
        self.database = database
        self.fetcher = fetcher
        self.state = initialState
    }

    // MARK: - Intent: present sign-in

    /// Opens the sign-in sheet. Used by both the initial "Connect" action (from
    /// `.notConnected`) and the "Reconnect" action (from `.authExpired` or a
    /// connected state). On success, kicks off an immediate fetch. On cancel,
    /// restores the state the store held before the sheet opened.
    public func presentSignIn() {
        // Ignore double-invocations while a sheet is already up.
        if activeSheet != nil { return }

        let priorState = state
        state = .connecting

        activeSheet = ClaudeCodeSignInSheet.present(
            onSuccess: { [weak self] in
                guard let self else { return }
                self.activeSheet = nil
                Task { @MainActor in
                    await self.fetchNow()
                }
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.activeSheet = nil
                // Restore the state we held before the sheet opened.
                self.state = priorState
            }
        )
    }

    // MARK: - Intent: fetch

    /// Forces an immediate fetch. Maps the result to the next state via
    /// `stateForFetchResult(_:previouslyConnectedAt:)`.
    public func fetchNow() async {
        let priorFetchAt: Date? = {
            if case .connected(let date) = state { return date }
            return nil
        }()

        let result: Result<[RemoteClaudeCodeSession], Error>
        do {
            let rows = try await fetcher.refresh()
            result = .success(rows)
        } catch {
            result = .failure(error)
        }

        // Update state BEFORE dispatching per-session fetches. The dispatched
        // Tasks await `fetcher.fetchLatestAssistantText`, and their post-await
        // `hasClaudeConnection` guard must observe the latest state — not a
        // stale value from a prior fetch outcome. Setting state first decouples
        // dispatch from any "must be synchronous through dispatch" invariant.
        state = Self.stateForFetchResult(result, previouslyConnectedAt: priorFetchAt)

        // On success only — prune stale cache entries and dispatch per-session
        // events fetches for any session whose `lastEventAt` advanced (or
        // appeared for the first time). Failures intentionally skip this step
        // so cached summaries survive auth-expired / transient-error blips.
        if case .success(let rows) = result {
            pruneRemoteAwaySummaryState(keepingIds: Set(rows.map(\.id)))
            for session in rows {
                dispatchAwaySummaryFetchIfNeeded(for: session)
            }
        }
    }

    /// Drop cache + map entries for session IDs no longer present in the
    /// latest list response. Mirrors `pruneTranscriptAwaySummaryCache` on the
    /// VM side. Does NOT cancel in-flight tasks for sessions that fell out of
    /// the list — they may simply not appear in the next page (pagination) or
    /// the user may resume one. Cancelling would just trade one race for
    /// another; the next `fetchNow()` will either rediscover the session or
    /// the task will complete and the guard in its body will drop the result.
    private func pruneRemoteAwaySummaryState(keepingIds live: Set<String>) {
        remoteAwaySummaryCache = remoteAwaySummaryCache.filter { live.contains($0.key) }
        remoteAwaySummariesById = remoteAwaySummariesById.filter { live.contains($0.key) }
    }

    /// If we don't already have a cached summary for `session.lastEventAt`
    /// (and no fetch is in flight for this id), spawn a Task to fetch the
    /// latest assistant text and write the result into the cache + map.
    /// Safe to call on every `fetchNow()`: the cache-hit and in-flight
    /// guards make redundant calls cheap.
    private func dispatchAwaySummaryFetchIfNeeded(for session: RemoteClaudeCodeSession) {
        // Bridged sessions are hidden by BridgeMatcher in favor of their local twin
        // (which already gets its own away_summary via the local JSONL transcript).
        // Skip the events fetch — the result would never reach a visible row.
        guard session.environmentKind != "bridge" else { return }

        let id = session.id
        let pinnedLastEventAt = session.lastEventAt

        // Cache hit? Skip — we already have a result (possibly nil) for this exact lastEventAt.
        if let cached = remoteAwaySummaryCache[id], cached.lastEventAt == pinnedLastEventAt {
            return
        }
        // Already fetching? Skip — the in-flight task will write the result.
        if awaySummaryFetchTasks[id] != nil {
            return
        }

        let dispatchID = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                // Identity-checked cleanup: only wipe OUR slot. A fresh dispatch
                // (post-disconnect+reconnect) would have a different UUID under
                // the same session id, so we must NOT remove its entry just
                // because we share an id with the prior, now-superseded task.
                if self?.awaySummaryFetchTasks[id]?.id == dispatchID {
                    self?.awaySummaryFetchTasks.removeValue(forKey: id)
                }
            }
            guard let self else { return }
            let result: String?
            do {
                result = try await self.fetcher.fetchLatestAssistantText(sessionId: id)
            } catch {
                // Cache the failure against this lastEventAt so we don't retry
                // until activity advances it. See doc on remoteAwaySummaryCache.
                result = nil
            }
            // Disconnect-race guard: if the cache was cleared while we were
            // awaiting (disconnect or .notConnected transition), don't repopulate.
            guard self.hasClaudeConnection else { return }
            self.remoteAwaySummaryCache[id] = (pinnedLastEventAt, result)
            if let result {
                self.remoteAwaySummariesById[id] = result
            } else {
                self.remoteAwaySummariesById.removeValue(forKey: id)
            }
        }
        awaySummaryFetchTasks[id] = PendingAwaySummaryFetch(id: dispatchID, task: task)
    }

    /// Wait for all in-flight `fetchLatestAssistantText` tasks dispatched by
    /// `fetchNow()` to complete. Used by tests to assert on cache state without
    /// flaky `Task.yield()` loops. Safe to call when no fetches are in flight
    /// (returns immediately).
    public func awaitPendingAwaySummaryFetches() async {
        // Snapshot the values — Task completions mutate the dict via defer,
        // so iterating live would crash.
        let tasks = awaySummaryFetchTasks.values.map(\.task)
        for task in tasks {
            _ = await task.value
        }
        // Some completions may have dispatched follow-up tasks (they shouldn't
        // by design, but be defensive). Re-snapshot once and drain.
        let followups = awaySummaryFetchTasks.values.map(\.task)
        for task in followups {
            _ = await task.value
        }
    }

    /// Kicks off an initial fetch (if cookies are present) and schedules a
    /// periodic refresh every `interval` seconds. Called from the app delegate
    /// at launch; safe to call once.
    public func startPeriodicFetching(interval: TimeInterval = 30) {
        periodicTimer?.invalidate()
        Task { @MainActor in await self.fetchNow() }
        periodicTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.fetchNow() }
        }
    }

    /// Pure state-mapping function for a single fetch outcome. Extracted so the
    /// state machine is fully exercisable from unit tests without any async
    /// plumbing, sheets, or real WebKit state.
    ///
    /// `nonisolated` because the function touches nothing on the store — it's
    /// straight in/out so tests don't need to hop onto the main actor to call it.
    public nonisolated static func stateForFetchResult(
        _ result: Result<[RemoteClaudeCodeSession], Error>,
        previouslyConnectedAt: Date?
    ) -> State {
        switch result {
        case .success:
            return .connected(lastFetchAt: Date())
        case .failure(let error):
            if let remote = error as? RemoteClaudeCodeError {
                switch remote {
                case .notConnected:
                    return .notConnected
                case .needsReauth:
                    return .authExpired
                case .http(let status):
                    return .transientError("HTTP \(status)")
                case .decode(let description):
                    return .transientError("Decode failed: \(description)")
                case .transport(let description):
                    return .transientError(description)
                }
            }
            return .transientError(error.localizedDescription)
        }
    }

    // MARK: - Intent: disconnect

    /// Clears `.claude.ai`-scoped cookies from the shared WebKit data store,
    /// wipes the cached remote session rows, and transitions to
    /// `.notConnected`. DB and state updates happen even if the cookie purge
    /// fails — the state machine must not get stuck mid-disconnect.
    public func disconnect() async {
        await Self.clearClaudeCookies()
        do {
            try database.clearRemoteClaudeCodeSessions()
        } catch {
            // Cache clear is best-effort; the user's intent (to disconnect) is
            // preserved regardless.
        }
        // Clear the away-summary cache + map and cancel any in-flight fetches.
        // Must happen BEFORE the state transition so the disconnect-race guard
        // (`hasClaudeConnection`) in pending Task closures fires correctly
        // after the state flips to `.notConnected`.
        remoteAwaySummaryCache.removeAll()
        remoteAwaySummariesById = [:]
        for pending in awaySummaryFetchTasks.values { pending.task.cancel() }
        awaySummaryFetchTasks.removeAll()
        state = .notConnected
    }

    /// Purges every `.claude.ai`-scoped cookie from both the WebKit data
    /// store (used by the sign-in sheet's WebView) and `NSHTTPCookieStorage`
    /// (used by the fetcher + the persisted mirror). Both must be cleared or
    /// the sheet will auto-re-sync on next sign-in attempt.
    private static func clearClaudeCookies() async {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        let webKitCookies = await cookieStore.allCookies()
        for cookie in webKitCookies where cookie.domain.hasSuffix("claude.ai") {
            await cookieStore.deleteCookie(cookie)
        }
        let sharedStorage = HTTPCookieStorage.shared
        for cookie in sharedStorage.cookies ?? [] where cookie.domain.hasSuffix("claude.ai") {
            sharedStorage.deleteCookie(cookie)
        }
    }
}
