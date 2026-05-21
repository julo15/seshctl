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

        state = Self.stateForFetchResult(result, previouslyConnectedAt: priorFetchAt)
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
