import AppKit
import Combine
import Darwin
import Foundation
import SeshctlCore
import SeshctlRecall

@MainActor
public final class SessionListViewModel: ObservableObject {
    @Published public private(set) var sessions: [Session] = []
    @Published public private(set) var remoteSessions: [RemoteClaudeCodeSession] = []
    @Published public private(set) var error: String?
    @Published public var selectedIndex: Int = 0
    @Published public var isSearching: Bool = false
    @Published public var searchQuery: String = ""
    @Published public var isNavigatingSearch: Bool = false
    @Published public var pendingKillSessionId: String?
    /// True when the pending kill targets a row whose process is already gone,
    /// so confirming removes the row instead of signalling anything.
    @Published public private(set) var pendingKillRemovesRow: Bool = false
    @Published public var pendingForkSessionId: String?
    @Published public var pendingMarkAllRead: Bool = false
    @Published public var showingHelp: Bool = false
    @Published public private(set) var unreadSessionIds: Set<String> = []
    /// Local session IDs whose conversation also appears as a bridged remote
    /// row. Used by the row view to render a small cloud marker indicating
    /// "this terminal session is also bridged to claude.ai." Computed in
    /// `refresh()` via `BridgeMatcher`.
    @Published public private(set) var bridgedLocalIds: Set<String> = []
    /// Remote session IDs that are the bridged twin of a visible local row.
    /// Filtered out of `activeRows` / `recentRows` to prevent the pair from
    /// showing twice. Computed in `refresh()` via `BridgeMatcher`.
    @Published public private(set) var bridgedRemoteIds: Set<String> = []
    /// Full `localId -> remoteId` pairing — the third projection of the same
    /// single `BridgeMatcher` run that produces `bridgedLocalIds` and
    /// `bridgedRemoteIds`. Published so the two user-action handlers in
    /// `AppDelegate` (the cloud-glyph click closure and `openSelectedOnWeb`)
    /// can do a direct `localId -> remoteId` lookup when resolving the
    /// bridged twin's web URL. Not a render-path optimization: nothing reads
    /// this during row rendering or on the refresh tick, and
    /// `bridgedRemote(for:)` still scans `remoteSessions` to turn the id into
    /// a session. Computed in `refresh()` via `BridgeMatcher`.
    @Published public private(set) var bridgedRemoteIdByLocalId: [String: String] = [:]
    /// Latest Claude Code `away_summary` ("recap") per local session, keyed by
    /// `session.id`. Sessions without a recap are absent (the row falls
    /// through to its existing preview chain). Computed in `refresh()` via
    /// `TranscriptAwaySummaryScanner` with `transcriptAwaySummaryCache`
    /// providing mtime-based reuse so re-reads of unchanged transcripts are
    /// skipped on the 2-second refresh cadence.
    @Published public private(set) var awaySummariesById: [String: String] = [:]
    /// Timestamp of the most-recent panel-show event. Read by the row list's
    /// `.animation` modifier to suppress the reorder animation on the first
    /// refresh after the panel opens — without this, snapping from the
    /// last-known list (rendered before the panel was hidden) to the current
    /// list (loaded by the immediate `refresh()` in `panelDidShow()`) would
    /// run a full spring on every reopen.
    /// Write-ordering matters: `panelDidShow()` must set this *before* calling
    /// `refresh()` so the @Published mutations from refresh land in the same
    /// body-recomputation pass with the fresh timestamp visible.
    @Published public private(set) var lastPanelShownAt: Date = .distantPast
    /// Recency rank (and active state) of every row at the moment the panel
    /// opened; `nil` while hidden. See `sortedForDisplay(_:)`.
    private var frozenOrder: [String: (rank: Int, wasActive: Bool)]?
    /// Latest in-progress assistant text per local Claude session, keyed by
    /// `session.id`. Sessions without a current assistant-text turn are
    /// absent (the row falls through to its existing preview chain).
    /// Computed in `refresh()` via `TranscriptLatestAssistantScanner` with
    /// `transcriptLatestAssistantCache` providing mtime-based reuse so
    /// re-reads of unchanged transcripts are skipped on the 2-second refresh
    /// cadence. Surfaced to the row recap via a consumer-side collapse
    /// (`awaySummariesById[id] ?? latestAssistantById[id]`) into the existing
    /// `previewContent(awaySummary:)` slot — no new display branch.
    @Published public private(set) var latestAssistantById: [String: String] = [:]
    /// Short session title per local session, keyed by `session.id`. Claude
    /// Code titles (`ai-title`, falling back to `custom-title`) come from the
    /// transcript via `TranscriptTitleScanner`, with `transcriptTitleCache`
    /// resuming each transcript from the byte offset already scanned. Codex
    /// titles come from Codex's shared thread-name index via
    /// `CodexThreadNameIndex` (`codexThreadNameCache`). Sessions without a
    /// title are absent (the row falls back to the branch, then the folder).
    @Published public private(set) var titlesById: [String: String] = [:]
    /// Display name of the model each local Claude or Codex session last
    /// used (e.g. `"Opus 5.5"`), keyed by `session.id`, for the row's model
    /// pill. Absent when the transcript names no model. Computed in
    /// `refresh()` via `TranscriptModelScanner`, cached per transcript mtime
    /// in `transcriptModelCache`.
    @Published public private(set) var modelsById: [String: String] = [:]
    /// The most common model per agent across the listed rows, local and
    /// cloud. A row whose model differs from its agent's usual one gets a
    /// highlighted pill. See `isUnusualModel(_:tool:)`.
    @Published public private(set) var usualModelByTool: [SessionTool: String] = [:]
    /// Per-transcript cache: `path → (mtime, cseId)`. Lets `refresh()` skip
    /// re-reading a live Claude transcript when its file mtime hasn't
    /// advanced. Bounded by `sessions.count` on each refresh (entries for
    /// paths no longer present in the session list are evicted).
    private var transcriptBridgeCache: [String: (mtime: Date, cseId: String?)] = [:]
    /// Per-transcript cache: `path → (mtime, awaySummary)`. Mirrors
    /// `transcriptBridgeCache` for Claude Code recaps. Pruned by
    /// `pruneTranscriptAwaySummaryCache(keepingPaths:)` on each refresh.
    private var transcriptAwaySummaryCache: [String: (mtime: Date, summary: String?)] = [:]
    /// Per-transcript cache: `path → (mtime, latestAssistantText)`. Mirrors
    /// `transcriptAwaySummaryCache` for the live in-progress assistant text.
    /// Pruned by `pruneTranscriptLatestAssistantCache(keepingPaths:)` on each
    /// refresh.
    private var transcriptLatestAssistantCache: [String: (mtime: Date, text: String?)] = [:]
    /// Per-transcript scan state for session titles: `path → State`. Unlike
    /// the mtime caches above, this resumes from the byte offset already
    /// scanned, so an actively-growing transcript costs only its appended
    /// bytes per refresh (see `TranscriptTitleScanner`). Pruned by
    /// `pruneTranscriptTitleCache(keepingPaths:)` on each refresh.
    private var transcriptTitleCache: [String: TranscriptTitleScanner.State] = [:]
    /// Per-transcript cache: `path → (mtime, rawModel)`. Mirrors
    /// `transcriptLatestAssistantCache`. Pruned by
    /// `pruneTranscriptModelCache(keepingPaths:)` on each refresh.
    private var transcriptModelCache: [String: (mtime: Date, model: String?)] = [:]
    /// Scan state per Codex `session_index.jsonl`: `index path → State`. One
    /// index names every thread under a Codex home, so this is keyed by the
    /// index rather than per session, and resumes from the byte offset
    /// already scanned. Rebuilt each refresh from the indexes still in use.
    private var codexThreadNameCache: [String: CodexThreadNameIndex.State] = [:]
    /// Root that transcript resolution falls back to when a session's stored
    /// path is stale (`~/.claude/projects` in production; a temp dir in tests).
    private let projectsRoot: URL

    /// Transcript paths currently held in the title cache. Test-only window
    /// onto pruning: a cache keyed or pruned on the wrong path silently turns
    /// every refresh back into a full rescan.
    var titleCachePaths: Set<String> { Set(transcriptTitleCache.keys) }
    /// Codex index paths currently held in the thread-name cache. Test-only.
    var codexThreadNameCachePaths: Set<String> { Set(codexThreadNameCache.keys) }
    @Published public private(set) var recallResults: [RecallResult] = []
    @Published public private(set) var isRecallSearching: Bool = false
    @Published public private(set) var recallIndexingDone: Int?
    @Published public private(set) var recallIndexingTotal: Int?
    /// User-facing one-line failure message for the semantic search
    /// section. Populated on any `RecallError` (the detail is truncated
    /// via `firstLine` to keep the row compact). Cleared on every new
    /// search, on `exitSearch()`, and when the query empties.
    ///
    /// (v0.5.0 native recall: `.notInstalled` is no longer reachable —
    /// the native EmbeddingService is always available — but the case
    /// stays in `RecallError` and we route it through this same message
    /// path defensively.)
    @Published public private(set) var recallErrorMessage: String?
    @Published public private(set) var recallGeneration: Int = 0
    /// One-time toast flag: set to `true` when the user presses `x` with a
    /// cloud row selected. The view observes this, renders a toast, then
    /// calls `acknowledgeCloudKillToast()` to reset.
    @Published public private(set) var showedCloudKillToast: Bool = false

    private let database: SeshctlDatabase
    private let refreshInterval: TimeInterval
    private let enableGC: Bool
    private var timer: Timer?
    private var lastGC: Date = .distantPast
    private let gcInterval: TimeInterval = 60  // GC at most once per minute
    private var lastFocusedSessionId: String?
    private var lastFocusedAt: Date?
    private let focusMemoryWindow: TimeInterval
    private var recallSearchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private var isApplyingTransientReset: Bool = false

    private static let isTreeModeDefaultsKey = "seshctl.isTreeMode"
    private static let lastClosedAtKey = "seshctl.lastClosedAt"
    private static let sourceFilterDefaultsKey = "seshctl.sourceFilter"

    /// Which subset of sessions the list shows. Cycled by the `r` hotkey.
    public enum SourceFilter: String, CaseIterable, Sendable {
        case all
        case localOnly
        case remoteOnly

        /// Cycle order: all -> localOnly -> remoteOnly -> all.
        public var next: SourceFilter {
            switch self {
            case .all: return .localOnly
            case .localOnly: return .remoteOnly
            case .remoteOnly: return .all
            }
        }

        // `.all` includes both; `.localOnly`/`.remoteOnly` each exclude the other.
        fileprivate var includesLocal: Bool { self != .remoteOnly }
        fileprivate var includesRemote: Bool { self != .localOnly }
    }

    /// Which empty-state slot the list view should render in place of the
    /// row list. Returned by `emptyState`; `nil` means render the normal
    /// row list (or tree).
    public enum EmptyStateKind: Sendable {
        /// Neither local nor remote sessions exist anywhere — point the
        /// user at starting a CLI session.
        case fullyEmpty
        /// No actives under the current filter, but recents are reachable
        /// via search — point the user at `/`.
        case recentsOnly
        /// The current filter excludes every session — point the user at
        /// `r` to change the filter.
        case filteredOut
        /// The `c` view has nothing to reopen — point the user back.
        case noClosedSessions
    }
    public static let inboxBurstWindow: TimeInterval = 10 // 10-second "don't switch under the user" window
    /// Synthetic group name for cloud rows that have no git_repository source.
    public static let cloudNoRepoGroupName: String = "Cloud — no repo"

    /// Whether the seshboard is rendering the repo-grouped tree view.
    /// Not `@AppStorage` — `@AppStorage` is a `DynamicProperty` that does not
    /// fire `objectWillChange` inside an `ObservableObject`, so views bound to
    /// the viewmodel would not re-render on toggle. We store manually and
    /// write-through to the injected `UserDefaults` in `didSet`.
    @Published public var isTreeMode: Bool {
        didSet {
            if isApplyingTransientReset { return }
            defaults.set(isTreeMode, forKey: Self.isTreeModeDefaultsKey)
        }
    }

    /// `c` view: closed sessions only, one row per conversation, so a closed
    /// session can be found and reopened (Enter) without typing a query.
    /// Overrides tree mode while on, without touching the persisted
    /// `isTreeMode`. Reset every time the panel opens.
    @Published public private(set) var isRecentsMode = false

    /// Closed sessions for the `c` view, from `listRecentSessions`. Only
    /// loaded while `isRecentsMode` is on, so the live list pays nothing.
    @Published public private(set) var recentSessions: [Session] = []

    /// Resolved transcript paths for `c` rows outside the newest-50
    /// `sessions`, so titles can be scanned for them. Cached for as long as
    /// the view is open: a closed session's transcript doesn't move, and
    /// resolving can glob `~/.claude/projects/`. `nil` = resolved, not found.
    private var closedTranscriptPaths: [String: String?] = [:]

    /// Source filter. `didSet` persists to UserDefaults (not `@AppStorage`
    /// for the same reason as `isTreeMode`).
    @Published public var sourceFilter: SourceFilter {
        didSet {
            defaults.set(sourceFilter.rawValue, forKey: Self.sourceFilterDefaultsKey)
        }
    }

    public init(database: SeshctlDatabase, refreshInterval: TimeInterval = 2.0, enableGC: Bool = true, focusMemoryWindow: TimeInterval = 30, defaults: UserDefaults = .standard, projectsRoot: URL = TranscriptParser.defaultProjectsRoot) {
        self.database = database
        self.projectsRoot = projectsRoot
        self.refreshInterval = refreshInterval
        self.enableGC = enableGC
        self.focusMemoryWindow = focusMemoryWindow
        self.defaults = defaults
        self.isTreeMode = defaults.bool(forKey: Self.isTreeModeDefaultsKey)
        let raw = defaults.string(forKey: Self.sourceFilterDefaultsKey) ?? SourceFilter.all.rawValue
        self.sourceFilter = SourceFilter(rawValue: raw) ?? .all
    }

    public func startPolling() {
        // Don't start a timer — polling is driven by show/hide
    }

    /// Call when the panel becomes visible. Refreshes immediately and starts polling.
    public func panelDidShow() {
        // Set BEFORE refresh() so the body recomputation triggered by the
        // refresh's @Published mutations sees the fresh `lastPanelShownAt`
        // and suppresses the reorder spring.
        lastPanelShownAt = Date()
        frozenOrder = nil
        refresh()
        freezeOrder()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    /// Call when the panel is hidden. Stops polling.
    public func panelDidHide() {
        timer?.invalidate()
        timer = nil
        frozenOrder = nil
        pendingKillSessionId = nil
        pendingForkSessionId = nil
        pendingMarkAllRead = false
        showingHelp = false
    }

    public func stopPolling() {
        panelDidHide()
    }

    /// Record the time the panel was closed. Used by
    /// `applyInboxAwareResetIfNeeded` to decide whether a reopen is part of a
    /// quick close/reopen burst (keep tree mode) or a fresh inbox glance
    /// (transiently flip to list view).
    public func recordPanelClose(now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastClosedAtKey)
    }

    /// When the panel opens in tree mode and more than `burstWindow` seconds
    /// have elapsed since the last recorded close, transiently flip to list
    /// view so the user gets an "inbox glance". The flip does NOT persist —
    /// pressing `v` afterwards writes normally, so the user can return to tree
    /// mode with a single keystroke. Returns `true` if a flip was applied.
    ///
    /// Selection is intentionally NOT remapped by session.id — this is a view-presentation policy, not a user toggle. Callers should invoke `resetSelection()` afterwards if selection should follow the remembered focus.
    @discardableResult
    public func applyInboxAwareResetIfNeeded(now: Date = Date(), burstWindow: TimeInterval = SessionListViewModel.inboxBurstWindow) -> Bool {
        guard isTreeMode else { return false }
        let lastClosedAt = defaults.double(forKey: Self.lastClosedAtKey)
        // Missing/zero `lastClosedAt` (e.g. first open after install) behaves
        // as "> burstWindow elapsed" because the difference vs. `now` is huge.
        let elapsed = now.timeIntervalSince1970 - lastClosedAt
        if elapsed <= burstWindow { return false }
        isApplyingTransientReset = true
        isTreeMode = false
        isApplyingTransientReset = false
        return true
    }

    public func refresh() {
        do {
            // Capture the id of the currently selected row before the refresh
            // mutates state. `selectedIndex` is an integer position, so when
            // rows reorder we'd otherwise leave the highlight pinned to the
            // slot — pointing at a different row. After the mutations land
            // we look this id up in the new `orderedRows` and re-pin
            // `selectedIndex` to the row's new position.
            let priorSelectedRowId: String? = {
                let rows = orderedRows
                guard selectedIndex >= 0, selectedIndex < rows.count else { return nil }
                return rows[selectedIndex].id
            }()
            if enableGC {
                try database.reapStaleSessions()
            }
            if enableGC && Date().timeIntervalSince(lastGC) > gcInterval {
                try database.gc(olderThan: 30 * 24 * 3600)
                lastGC = Date()
            }
            sessions = try database.listSessions(limit: 50)
            if isRecentsMode {
                // Assign only on change: a fresh array every 2s would
                // re-render the list even when nothing closed.
                let latest = try database.listRecentSessions(reopenableOnly: true)
                if latest != recentSessions { recentSessions = latest }
            }
            remoteSessions = try database.listRemoteClaudeCodeSessions()
            var unread = Set(sessions.filter { session in
                let actionable = session.status == .idle || session.status == .waiting || session.status == .completed || session.status == .canceled || session.status == .stale
                guard actionable else { return false }
                guard let lastReadAt = session.lastReadAt else { return true }
                return session.updatedAt > lastReadAt
            }.map(\.id))
            for remote in remoteSessions where remote.isUnread {
                unread.insert(remote.id)
            }
            unreadSessionIds = unread
            // Resolve every live Claude session's transcript path once for
            // this refresh cycle and reuse the URL across all three cached
            // scanners + the prune step. Without this the resolver (incl. a
            // possible `~/.claude/projects/` glob walk) would run up to 4×
            // per session every 2 seconds. Non-Claude tools are skipped —
            // the scanners would early-out on them anyway.
            var resolvedPathsBySessionId: [String: String] = [:]
            for session in sessions where session.tool == .claude {
                if let path = TranscriptParser.resolveExistingTranscript(for: session, projectsRoot: projectsRoot)?.path {
                    resolvedPathsBySessionId[session.id] = path
                }
            }

            // Compute bridged pairs (local CLI session ↔ remote claude.ai
            // `environment_kind == "bridge"` session) by reading each live
            // Claude local's transcript for a bridge event, which identifies
            // the claude.ai session deterministically (both recognized event
            // shapes are documented on `TranscriptBridgeScanner`). Hides
            // the remote twin from the list and marks the local twin for
            // a cloud badge.
            let pairs = BridgeMatcher.match(
                locals: sessions,
                remotes: remoteSessions,
                bridgedRemoteId: { [weak self] session in
                    guard let path = resolvedPathsBySessionId[session.id] else { return nil }
                    return self?.cachedBridgedRemoteId(for: session, transcriptPath: path)
                }
            )
            bridgedLocalIds = Set(pairs.map(\.localId))
            bridgedRemoteIds = Set(pairs.map(\.remoteId))
            // `uniquingKeysWith` rather than `uniqueKeysWithValues`: BridgeMatcher
            // already emits at most one pair per local, but a trapping
            // initializer would turn any future relaxation of that invariant
            // into a crash on the 2-second refresh tick.
            bridgedRemoteIdByLocalId = Dictionary(
                pairs.map { ($0.localId, $0.remoteId) },
                uniquingKeysWith: { first, _ in first }
            )
            // Pull the latest Claude Code `away_summary` per local Claude session
            // into `awaySummariesById`. Reuses the per-transcript mtime cache to
            // skip re-reading unchanged JSONLs. Non-Claude tools are skipped at
            // the resolved-path lookup above.
            var summaries: [String: String] = [:]
            for session in sessions {
                guard let path = resolvedPathsBySessionId[session.id] else { continue }
                if let summary = cachedAwaySummary(for: session, transcriptPath: path) {
                    summaries[session.id] = summary
                }
            }
            awaySummariesById = summaries
            // Prune by the same resolved paths the cache helpers above keyed
            // entries under. Using `session.transcriptPath` directly would
            // evict live entries on every refresh whenever a session has
            // cd'd elsewhere (e.g. into a worktree) mid-session, because
            // the cache key is the resolved path, not the stored one.
            let livePaths = Array(resolvedPathsBySessionId.values)
            pruneTranscriptAwaySummaryCache(keepingPaths: livePaths)
            var latest: [String: String] = [:]
            for session in sessions {
                guard let path = resolvedPathsBySessionId[session.id] else { continue }
                if let text = cachedLatestAssistant(for: session, transcriptPath: path) {
                    latest[session.id] = text
                }
            }
            latestAssistantById = latest
            pruneTranscriptLatestAssistantCache(keepingPaths: livePaths)
            // The `c` view reaches past the newest 50 `sessions`; title its
            // older rows too, from whatever budget the live rows leave.
            var titlePaths = resolvedPathsBySessionId
            var titleSessions = sessions
            if isRecentsMode {
                let known = Set(sessions.map(\.id))
                for session in recentSessions where !known.contains(session.id) {
                    switch session.tool {
                    case .claude:
                        if closedTranscriptPaths[session.id] == nil {
                            closedTranscriptPaths[session.id] = .some(
                                TranscriptParser.resolveExistingTranscript(for: session, projectsRoot: projectsRoot)?.path)
                        }
                        if let path = closedTranscriptPaths[session.id] ?? nil {
                            titlePaths[session.id] = path
                            titleSessions.append(session)
                        }
                    case .codex:
                        titleSessions.append(session)
                    case .gemini, .cursor:
                        break
                    }
                }
            }
            // Sessions arrive most-recent first, so a cold cache spends its
            // per-refresh read budget on the rows at the top of the list.
            var titles: [String: String] = [:]
            var titleBudget = titleScanBytesPerRefresh
            var codexIndexes: [String: CodexThreadNameIndex.State] = [:]
            for session in titleSessions {
                let title: String?
                switch session.tool {
                case .claude:
                    guard let path = titlePaths[session.id] else { continue }
                    title = cachedTitle(for: session, transcriptPath: path, budget: &titleBudget)
                case .codex:
                    title = codexThreadName(for: session, scanned: &codexIndexes)
                case .gemini, .cursor:
                    title = nil
                }
                if let title { titles[session.id] = title }
            }
            titlesById = titles
            pruneTranscriptTitleCache(keepingPaths: Array(titlePaths.values))
            // Only indexes some listed session used this refresh survive.
            codexThreadNameCache = codexIndexes
            // Models for the pill. Claude paths are already resolved above
            // (live rows plus the `c` view's older ones); Codex rows use the
            // stored rollout path, which the hooks record verbatim.
            var modelPaths = titlePaths
            // Codex rows are added below with their rollout path, so leave out
            // the ones `titleSessions` carries rather than scan them twice.
            var modelSessions = titleSessions.filter { $0.tool != .codex }
            for session in sessions + (isRecentsMode ? recentSessions : []) where session.tool == .codex {
                guard modelPaths[session.id] == nil, let path = session.transcriptPath,
                      FileManager.default.fileExists(atPath: path) else { continue }
                modelPaths[session.id] = path
                modelSessions.append(session)
            }
            var models: [String: String] = [:]
            for session in modelSessions {
                guard let path = modelPaths[session.id],
                      let raw = cachedModel(for: session, transcriptPath: path) else { continue }
                models[session.id] = TranscriptModelScanner.displayName(for: raw)
            }
            if models != modelsById { modelsById = models }
            pruneTranscriptModelCache(keepingPaths: Array(modelPaths.values))
            let usual = Self.usualModels(
                local: sessions.compactMap { session in models[session.id].map { (session.tool, $0) } },
                remote: remoteSessions.map(\.model)
            )
            if usual != usualModelByTool { usualModelByTool = usual }
            pruneTranscriptBridgeCache(keepingPaths: livePaths)
            // Re-pin `selectedIndex` to the previously-selected row's new
            // position. If the row vanished (closed + filtered out of
            // `orderedRows`), clamp `selectedIndex` to the new array bounds
            // so the highlight lands on a real row instead of silently
            // sliding onto whichever row now occupies the old slot —
            // the exact bug the re-pin fixes for the reorder case.
            // Empty list → `-1` (the nothing-selected sentinel).
            if let id = priorSelectedRowId {
                if let newIndex = orderedRows.firstIndex(where: { $0.id == id }) {
                    if newIndex != selectedIndex {
                        selectedIndex = newIndex
                    }
                } else {
                    selectedIndex = min(selectedIndex, orderedRows.count - 1)
                }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Local-only session slices
    //
    // These properties retain the pre-refactor shape (`[Session]`) for
    // call sites that specifically want the local half. The view layer
    // renders via the `Rows` siblings below, which merge in remote rows.

    /// Local sessions filtered by search query when searching. The same six
    /// fields match as before — this is the local-only slice.
    public var localFilteredSessions: [Session] {
        guard isSearching, !searchQuery.isEmpty else { return sessions }
        return sessions.filter {
            Self.matches(session: $0, title: titlesById[$0.id], query: searchQuery)
        }
    }

    /// Split a query into lowercased tokens on whitespace.
    ///
    /// Tokens are ANDed across the row, fields are ORed within a token. A
    /// single `contains` over the whole query only matched when every word
    /// appeared consecutively in one field, so `sesh dedup` found nothing.
    /// Tokenized, it finds a `seshctl` row titled "Session deduplication
    /// verification".
    nonisolated static func searchTokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Static and `nonisolated` so the match rule tests without a view model,
    /// database, clock, or MainActor hop. An empty query matches everything.
    /// `title` comes from `titlesById`, since titles live outside `Session`.
    nonisolated static func matches(session: Session, title: String? = nil, query: String) -> Bool {
        let tokens = searchTokens(query)
        guard !tokens.isEmpty else { return true }
        let fields: [String?] = [
            session.directory,
            session.gitRepoName,
            session.gitBranch,
            session.lastAsk,
            session.lastReply,
            title,
            session.tool.rawValue,
        ]
        let haystack = fields.compactMap { $0?.lowercased() }
        return tokens.allSatisfy { token in
            haystack.contains { $0.contains(token) }
        }
    }

    /// Remote counterpart of `matches(session:query:)`. Same token rule over
    /// the three fields a cloud row carries, so one query can't behave
    /// differently on the two halves of a search.
    nonisolated static func matches(remote: RemoteClaudeCodeSession, query: String) -> Bool {
        let tokens = searchTokens(query)
        guard !tokens.isEmpty else { return true }
        let fields: [String?] = [
            remote.title,
            DisplayRow.repoShortName(from: remote.repoUrl),
            remote.branches.joined(separator: " "),
        ]
        let haystack = fields.compactMap { $0?.lowercased() }
        return tokens.allSatisfy { token in
            haystack.contains { $0.contains(token) }
        }
    }

    /// Local active sessions (idle, working, or waiting).
    public var localActiveSessions: [Session] {
        localFilteredSessions.filter { $0.isActive }
    }

    /// Local recent sessions (completed/canceled/stale).
    public var localRecentSessions: [Session] {
        localFilteredSessions.filter { !$0.isActive }
    }

    /// Local-only ordered list (active then recent). In tree mode, returns
    /// only the tree-ordered local sessions.
    public var localOrderedSessions: [Session] {
        if isTreeMode {
            return localTreeOrderedSessions
        }
        return localActiveSessions + localRecentSessions
    }

    /// Local-only flat tree order — matches the pre-refactor behavior for
    /// tests and call sites that need the tree grouping of just local
    /// sessions.
    public var localTreeOrderedSessions: [Session] {
        treeGroups.flatMap { group in
            group.rows.compactMap { row in
                if case .local(let s) = row { return s } else { return nil }
            }
        }
    }

    // MARK: - Unified row slices (local + remote)

    /// Remote sessions filtered by search query when searching. Matches
    /// `title`, derived repo short name, and `branches[]`.
    private var filteredRemoteSessions: [RemoteClaudeCodeSession] {
        guard isSearching, !searchQuery.isEmpty else { return remoteSessions }
        return remoteSessions.filter { Self.matches(remote: $0, query: searchQuery) }
    }

    /// Active rows: local `isActive == true` sessions plus remote sessions
    /// with `connection_status == "connected"`. Sorted by timestamp desc.
    /// Honors `sourceFilter` — hides either source entirely.
    public var activeRows: [DisplayRow] {
        let localActive: [DisplayRow] = sourceFilter.includesLocal
            ? localFilteredSessions.filter { $0.isActive }.map { .local($0) }
            : []
        let remoteActive: [DisplayRow] = sourceFilter.includesRemote
            ? filteredRemoteSessions
                .filter { $0.connectionStatus == "connected" }
                .filter { !bridgedRemoteIds.contains($0.id) }
                .map { .remote($0) }
            : []
        return sortedForDisplay(localActive + remoteActive)
    }

    /// Recent rows: local inactive sessions plus remote sessions not
    /// connected. Sorted by timestamp desc. Honors `sourceFilter`.
    public var recentRows: [DisplayRow] {
        let localRecent: [DisplayRow] = sourceFilter.includesLocal
            ? localFilteredSessions.filter { !$0.isActive }.map { .local($0) }
            : []
        let remoteRecent: [DisplayRow] = sourceFilter.includesRemote
            ? filteredRemoteSessions
                .filter { $0.connectionStatus != "connected" }
                .filter { !bridgedRemoteIds.contains($0.id) }
                .map { .remote($0) }
            : []
        return sortedForDisplay(localRecent + remoteRecent)
    }

    /// Sort rows newest-first — unless the panel is visible, in which case
    /// rows keep the order they had when it opened (`frozenOrder`). A row
    /// jumping to the top on every hook update moves the click target out
    /// from under the cursor, so recency only re-sorts on the next open.
    /// Rows the snapshot hasn't seen in their current active/recent state
    /// (a new session, or one that just resumed) go on top, newest-first.
    private func sortedForDisplay(_ rows: [DisplayRow]) -> [DisplayRow] {
        let byRecency = rows.sorted { $0.sortTimestamp > $1.sortTimestamp }
        guard let frozenOrder else { return byRecency }
        func rank(_ row: DisplayRow) -> Int? {
            guard let entry = frozenOrder[row.id], entry.wasActive == row.isActive else { return nil }
            return entry.rank
        }
        let unseen = byRecency.filter { rank($0) == nil }
        let seen = byRecency.compactMap { row in rank(row).map { (row, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        return unseen + seen
    }

    /// Freeze or release the display order while the panel stays visible.
    /// `panelDidShow()` freezes and `panelDidHide()` releases, but a pinned
    /// panel stays visible indefinitely, so the app also releases it when the
    /// pinned panel sits unfocused and unhovered (a glanceable dashboard that
    /// should keep re-sorting) and re-freezes when the user comes back to it.
    /// Freezing while already frozen keeps the original snapshot.
    public func setOrderFrozen(_ frozen: Bool) {
        if !frozen {
            frozenOrder = nil
        } else if frozenOrder == nil {
            freezeOrder()
        }
    }

    /// Snapshot every row's recency rank, across both sources and ignoring
    /// search and source filters, so any subset sorted by these ranks keeps
    /// its relative order from when the panel opened.
    private func freezeOrder() {
        let all = sessions.map(DisplayRow.local) + remoteSessions.map(DisplayRow.remote)
        let byRecency = all.sorted { $0.sortTimestamp > $1.sortTimestamp }
        var order: [String: (rank: Int, wasActive: Bool)] = [:]
        for (index, row) in byRecency.enumerated() where order[row.id] == nil {
            order[row.id] = (index, row.isActive)
        }
        frozenOrder = order
    }

    /// The view-facing filtered + mode-aware row list. Tree mode and the
    /// default list view both surface only `activeRows` — closed/
    /// disconnected sessions stay out of the seshboard. The exception
    /// is search: while `isSearching` is true, `recentRows` rejoin so
    /// the user can find a historical session by name / repo / branch.
    /// Note the gate is on the search *bar*, not the *query*: an empty
    /// `searchQuery` still surfaces recents the moment `isSearching`
    /// flips to true, so the user sees the full corpus to start
    /// narrowing from.
    public var filteredRows: [DisplayRow] {
        if isRecentsMode {
            return closedRows
        }
        if isTreeMode {
            return treeOrderedRows
        }
        if isSearching {
            return activeRows + recentRows
        }
        return activeRows
    }

    /// Rows for the `c` view: deduped closed local sessions plus disconnected
    /// cloud rows, narrowed by `/` and the source filter.
    public var closedRows: [DisplayRow] {
        let local: [DisplayRow] = sourceFilter.includesLocal
            ? recentSessions
                .filter { !isSearching || Self.matches(session: $0, title: titlesById[$0.id], query: searchQuery) }
                .map { .local($0) }
            : []
        let remote: [DisplayRow] = sourceFilter.includesRemote
            ? filteredRemoteSessions
                .filter { $0.connectionStatus != "connected" }
                .filter { !bridgedRemoteIds.contains($0.id) }
                .map { .remote($0) }
            : []
        // Plain recency, not `sortedForDisplay`: the frozen order snapshots
        // only the newest 50 `sessions`, so closed rows beyond them would
        // count as "unseen" and sort above newer ones. Closed rows don't
        // change under the user anyway, which is what freezing guards against.
        return (local + remote).sorted { $0.sortTimestamp > $1.sortTimestamp }
    }

    public func toggleRecentsMode() {
        isRecentsMode ? exitRecentsMode() : enterRecentsMode()
    }

    public func enterRecentsMode() {
        pendingKillSessionId = nil
        pendingForkSessionId = nil
        pendingMarkAllRead = false
        isRecentsMode = true
        refresh()
        selectedIndex = orderedRows.isEmpty ? -1 : 0
    }

    public func exitRecentsMode() {
        guard isRecentsMode else { return }
        isRecentsMode = false
        recentSessions = []
        closedTranscriptPaths = [:]
        selectedIndex = orderedRows.isEmpty ? -1 : 0
    }

    /// Esc / `q` in the list: leave the `c` view if it's open. Returns false
    /// when there was nothing to back out of, so the caller closes the panel.
    @discardableResult
    public func backOutOfRecentsMode() -> Bool {
        guard isRecentsMode else { return false }
        exitRecentsMode()
        return true
    }

    /// Ordered rows the view renders. Matches `filteredRows`; retained as
    /// a separate name to keep intent clear at call sites.
    public var orderedRows: [DisplayRow] { filteredRows }

    /// The empty-state slot the list view should render, or `nil` if the
    /// normal row list / tree should render instead. Centralizes the
    /// four-branch routing the view used to encode inline so the policy
    /// is unit-testable and the view collapses to a single `switch`.
    ///
    /// - `.fullyEmpty` wins over filter state (truly nothing to show).
    /// - `isSearching` returns `nil` so the search UI stays visible while
    ///   the user is typing, even when nothing matches.
    /// - The `sourceFilter != .all` guard on `.filteredOut` is defensive:
    ///   with `.all`, an empty `filteredRows`/`recentRows` implies both
    ///   row sets are empty, which `.fullyEmpty` already caught.
    public var emptyState: EmptyStateKind? {
        if sessions.isEmpty && remoteSessions.isEmpty {
            return .fullyEmpty
        }
        if isSearching { return nil }
        if isRecentsMode {
            return closedRows.isEmpty ? .noClosedSessions : nil
        }
        guard filteredRows.isEmpty else { return nil }
        if !recentRows.isEmpty {
            return .recentsOnly
        }
        if sourceFilter != .all {
            return .filteredOut
        }
        return nil
    }

    /// True when the visible row list contains rows from more than one
    /// agent kind (e.g. Claude + Gemini, or Claude + Codex). Drives the
    /// agent corner badge on each row: when only one agent kind is
    /// visible the badge is redundant and gets suppressed by the row
    /// views. Remote rows always count as Claude (they live on
    /// claude.ai), matching `AgentBadgeSpec.forRemote` — so a fleet of
    /// local Claude + remote Claude rows collapses to one kind and
    /// correctly suppresses the badge.
    public var hasMultipleAgentTypes: Bool {
        var seen: Set<SessionTool> = []
        for row in orderedRows {
            switch row {
            case .local(let s): seen.insert(s.tool)
            case .remote:       seen.insert(.claude)
            }
            if seen.count > 1 { return true }
        }
        return false
    }

    /// Count of currently-open sessions with a claude.ai presence — i.e. cloud
    /// exposure. Sum of (bridged local sessions that are active) + (remote
    /// sessions that are connected and not bridged twins). Filter-agnostic: this
    /// reflects actual cloud footprint, not what's visible after applying
    /// `sourceFilter` or search.
    /// The `$0.isActive` check in the bridged-local leg is defensive —
    /// `BridgeMatcher.match` already emits only active-local pairs, but keeping
    /// the check local means a future `BridgeMatcher` relaxation can't silently
    /// inflate the count.
    public var remoteSessionCount: Int {
        let activeBridgedLocals = sessions.filter {
            $0.isActive && bridgedLocalIds.contains($0.id)
        }.count
        let connectedPureRemotes = remoteSessions.filter {
            $0.connectionStatus == "connected" && !bridgedRemoteIds.contains($0.id)
        }.count
        return activeBridgedLocals + connectedPureRemotes
    }

    /// The currently selected row, or nil if selection is out of range or
    /// refers to the recall section.
    public var selectedRow: DisplayRow? {
        let rows = orderedRows
        guard !rows.isEmpty, selectedIndex >= 0, selectedIndex < rows.count else {
            return nil
        }
        return rows[selectedIndex]
    }

    /// The currently selected local session, if any. Returns nil when the
    /// selection refers to a remote row or is out of range.
    public var selectedSession: Session? {
        if case .local(let session) = selectedRow { return session }
        return nil
    }

    /// The bridged claude.ai twin of a local session, if the pair is live.
    /// `nil` for unbridged locals and for pairs whose remote has since
    /// dropped out of `remoteSessions`.
    public func bridgedRemote(for session: Session) -> RemoteClaudeCodeSession? {
        guard let remoteId = bridgedRemoteIdByLocalId[session.id] else { return nil }
        return remoteSessions.first { $0.id == remoteId }
    }

    /// claude.ai URL for the selected row's cloud presence, or `nil` when the
    /// selection has none. Two cases resolve:
    /// - a remote row: its own `webUrl`,
    /// - a bridged local row: its remote twin's `webUrl`.
    ///
    /// An unbridged local row (or a recall result) returns `nil` — there is no
    /// web-side session to open, so the caller no-ops rather than guessing.
    public var selectedWebUrl: URL? {
        switch selectedRow {
        case .remote(let remote):
            return remote.webUrl
        case .local(let session):
            return bridgedRemote(for: session)?.webUrl
        case nil:
            return nil
        }
    }

    public func moveSelectionUp() {
        pendingKillSessionId = nil
        pendingForkSessionId = nil
        pendingMarkAllRead = false
        // Guard on the navigable ordering, not `sessions`. When the current
        // ordering is empty (e.g., filtered search results), preserve the
        // `selectedIndex = -1` empty-selection sentinel instead of clobbering
        // it to 0.
        guard totalResultCount > 0 else { return }
        selectedIndex = max(0, selectedIndex - 1)
    }

    public func moveToTop() {
        pendingKillSessionId = nil
        pendingForkSessionId = nil
        guard totalResultCount > 0 else { return }
        selectedIndex = 0
    }

    public func moveToBottom() {
        pendingKillSessionId = nil
        pendingForkSessionId = nil
        let count = totalResultCount
        guard count > 0 else { return }
        selectedIndex = count - 1
    }

    /// A group of active rows (local + remote) sharing a `(name, isRepo)` key.
    /// Rendered as a header row followed by its rows in tree mode.
    public struct SessionGroup: Equatable, Identifiable {
        public let name: String
        public let isRepo: Bool
        public let rows: [DisplayRow]

        /// Stable identifier combining name and repo-backed flag. Matches the
        /// prior file-scope `groupID` extension so `.id(...)` scroll targets
        /// keep working.
        public var id: String { "group-\(name)-\(isRepo)" }
    }

    /// Active rows bucketed by `(name, isRepo)`. Local rows key by
    /// `session.primaryName`; remote rows key by their repo short name. Remote
    /// rows with no repo URL go into a synthetic "Cloud — no repo" group.
    /// Groups sorted alphabetically case-insensitive by name; ties broken
    /// with repo-backed groups first. Rows inside a group sorted by
    /// `sortTimestamp` desc.
    public var treeGroups: [SessionGroup] {
        struct Key: Hashable {
            let name: String
            let isRepo: Bool
        }
        var buckets: [Key: [DisplayRow]] = [:]

        // Local active sessions, keyed on primaryName + isRepo.
        if sourceFilter.includesLocal {
            for session in localActiveSessions {
                let key = Key(name: session.primaryName, isRepo: session.gitRepoName != nil)
                buckets[key, default: []].append(.local(session))
            }
        }

        // Remote active rows, keyed on repo short name (fall back to cloud-no-repo).
        if sourceFilter.includesRemote {
            for remote in filteredRemoteSessions where remote.connectionStatus == "connected" {
                if let short = DisplayRow.repoShortName(from: remote.repoUrl) {
                    let key = Key(name: short, isRepo: true)
                    buckets[key, default: []].append(.remote(remote))
                } else {
                    let key = Key(name: Self.cloudNoRepoGroupName, isRepo: false)
                    buckets[key, default: []].append(.remote(remote))
                }
            }
        }

        let keys = buckets.keys.sorted { lhs, rhs in
            let lname = lhs.name.lowercased()
            let rname = rhs.name.lowercased()
            if lname != rname { return lname < rname }
            // Tie-break: repo-backed groups come first.
            if lhs.isRepo != rhs.isRepo { return lhs.isRepo && !rhs.isRepo }
            return false
        }
        return keys.map { key in
            let sorted = sortedForDisplay(buckets[key] ?? [])
            return SessionGroup(name: key.name, isRepo: key.isRepo, rows: sorted)
        }
    }

    /// Flat row sequence in group/row order. Header rows are NOT included
    /// — `selectedIndex` indexes this sequence in tree mode.
    public var treeOrderedRows: [DisplayRow] {
        treeGroups.flatMap(\.rows)
    }

    /// Cycle `sourceFilter` through all -> localOnly -> remoteOnly -> all.
    /// Always snaps selection to the top of the new ordering (or the
    /// `-1` sentinel when empty).
    public func cycleSourceFilter() {
        // `r` implicitly dismisses any pending confirmation modal — cycling
        // the filter would discard the relevant selection anyway, and this
        // keeps the hotkey from quietly swallowing the user's `y/n` decision.
        pendingKillSessionId = nil
        pendingForkSessionId = nil
        pendingMarkAllRead = false
        sourceFilter = sourceFilter.next
        selectedIndex = orderedRows.isEmpty ? -1 : 0
    }

    /// Toggle between list and tree mode. Remap `selectedIndex` by
    /// `row.id` so the same row stays selected across the switch.
    /// Falls back to index 0 when the prior row isn't in the new ordering,
    /// or `-1` when the new ordering is empty.
    public func toggleViewMode() {
        // The `c` view overrides tree mode, so toggling here would flip the
        // saved preference with nothing visible to show for it.
        guard !isRecentsMode else { return }
        pendingKillSessionId = nil
        pendingForkSessionId = nil
        pendingMarkAllRead = false
        let prior = orderedRows
        let priorSelected: DisplayRow? = {
            guard selectedIndex >= 0, selectedIndex < prior.count else { return nil }
            return prior[selectedIndex]
        }()
        isTreeMode.toggle()
        let next = orderedRows
        if next.isEmpty {
            selectedIndex = -1
            return
        }
        if let target = priorSelected, let idx = next.firstIndex(where: { $0.id == target.id }) {
            selectedIndex = idx
        } else {
            selectedIndex = 0
        }
    }

    /// Total number of items across all sections (rows + recall).
    public var totalResultCount: Int {
        if isSearching {
            return orderedRows.count + recallResults.count
        }
        return orderedRows.count
    }

    /// The currently selected recall result, if the selection is in the semantic section.
    public var selectedRecallResult: RecallResult? {
        let rowsCount = orderedRows.count
        guard isSearching, selectedIndex >= rowsCount else { return nil }
        let recallIndex = selectedIndex - rowsCount
        guard recallIndex >= 0, recallIndex < recallResults.count else { return nil }
        return recallResults[recallIndex]
    }

    public func moveSelectionDown() {
        pendingKillSessionId = nil
        pendingForkSessionId = nil
        pendingMarkAllRead = false
        let count = totalResultCount
        guard count > 0 else { return }
        selectedIndex = min(count - 1, selectedIndex + 1)
    }

    /// Jump selection to the first row of the next group in tree mode.
    /// No-op in list mode, when the tree is empty, or when already at/past the
    /// last group. Preserves the `-1` sentinel when `treeOrderedRows` is
    /// empty.
    public func jumpToNextGroup() {
        pendingKillSessionId = nil
        pendingForkSessionId = nil
        pendingMarkAllRead = false
        guard isTreeMode, !isRecentsMode else { return }
        // Explicit no-op when there's no current selection — callers may invoke
        // this before any row has been selected, and we shouldn't silently
        // clobber the `-1` sentinel.
        guard selectedIndex >= 0 else { return }
        let ordered = treeOrderedRows
        guard !ordered.isEmpty else { return }
        let groups = treeGroups

        // Build (groupIndex, firstFlatIndex) pairs.
        var starts: [Int] = []
        var running = 0
        for group in groups {
            starts.append(running)
            running += group.rows.count
        }

        // Out-of-range selectedIndex (non-negative but beyond the tree) — no-op.
        guard selectedIndex < ordered.count else { return }

        // Find current group index.
        var currentGroup = 0
        for (idx, start) in starts.enumerated() {
            let end = start + groups[idx].rows.count
            if selectedIndex >= start && selectedIndex < end {
                currentGroup = idx
                break
            }
        }
        let nextGroup = currentGroup + 1
        guard nextGroup < groups.count else { return }
        selectedIndex = starts[nextGroup]
    }

    /// Jump selection to the first row of the current group, or if already
    /// there, to the first row of the previous group. No-op at the first
    /// row of the first group, when the tree is empty, or in list mode.
    public func jumpToPreviousGroup() {
        pendingKillSessionId = nil
        pendingForkSessionId = nil
        pendingMarkAllRead = false
        guard isTreeMode, !isRecentsMode else { return }
        // Explicit no-op when there's no current selection — preserve the `-1`
        // sentinel rather than landing on the first group.
        guard selectedIndex >= 0 else { return }
        let ordered = treeOrderedRows
        guard !ordered.isEmpty else { return }
        let groups = treeGroups

        var starts: [Int] = []
        var running = 0
        for group in groups {
            starts.append(running)
            running += group.rows.count
        }

        // Out-of-range selectedIndex (non-negative but beyond the tree) — no-op.
        guard selectedIndex < ordered.count else { return }

        var currentGroup = 0
        for (idx, start) in starts.enumerated() {
            let end = start + groups[idx].rows.count
            if selectedIndex >= start && selectedIndex < end {
                currentGroup = idx
                break
            }
        }

        // Not at the first row of this group → jump to the group's first row.
        if selectedIndex > starts[currentGroup] {
            selectedIndex = starts[currentGroup]
            return
        }

        // Already at the first row of the first group → explicit no-op.
        guard currentGroup > 0 else { return }

        // Already at the first row of the current group → go to previous group.
        selectedIndex = starts[currentGroup - 1]
    }

    public func moveSelectionBy(_ delta: Int) {
        pendingKillSessionId = nil
        pendingForkSessionId = nil
        pendingMarkAllRead = false
        let count = totalResultCount
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    public func rememberFocusedSession(_ session: Session) {
        lastFocusedSessionId = session.id
        lastFocusedAt = Date()
    }

    /// Remember the row currently focused so `resetSelection()` can restore
    /// it after a refresh/reorder. Works for both local and remote rows.
    public func rememberFocusedRow(_ row: DisplayRow) {
        lastFocusedSessionId = row.id
        lastFocusedAt = Date()
    }

    /// Remember the currently selected row, whatever its type. Used by the
    /// actions that bypass `SessionAction`'s local-only `rememberFocused`
    /// closure — Enter on a remote row and the open-on-web paths — so a quick
    /// reopen lands back on that row instead of the top of the list.
    public func rememberSelectedRow() {
        guard let row = selectedRow else { return }
        rememberFocusedRow(row)
    }

    /// Scan the session's transcript for a bridged cse_id (see
    /// `TranscriptBridgeScanner` for the event shapes it recognizes), re-using a
    /// previous result when the transcript's mtime hasn't advanced. Non-Claude
    /// tools return nil without a filesystem hit — Codex/Gemini transcripts
    /// can't contain a Claude bridge event, and skipping them avoids multi-MB
    /// reads on every 2-second refresh. The caller resolves the transcript
    /// once per `refresh()` (via `TranscriptParser.resolveExistingTranscript`)
    /// and passes the path in, so sessions that `cd`'d mid-session
    /// (the row-recap-broken-after-worktree-entry case) still find their
    /// file.
    fileprivate func cachedBridgedRemoteId(for session: Session, transcriptPath path: String) -> String? {
        guard session.tool == .claude else { return nil }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let mtime, let cached = transcriptBridgeCache[path], cached.mtime == mtime {
            return cached.cseId
        }
        let cseId = TranscriptBridgeScanner.extractBridgedRemoteId(transcriptPath: path)
        if let mtime {
            transcriptBridgeCache[path] = (mtime, cseId)
        }
        return cseId
    }

    /// Drop cache entries for transcripts whose owning session is no longer
    /// in the live list. Keeps the cache size bounded by the session count.
    fileprivate func pruneTranscriptBridgeCache(keepingPaths paths: [String]) {
        let live = Set(paths)
        transcriptBridgeCache = transcriptBridgeCache.filter { live.contains($0.key) }
    }

    /// Scan the session's transcript for the latest `away_summary` content,
    /// re-using a previous result when the transcript's mtime hasn't
    /// advanced. Mirrors `cachedBridgedRemoteId(for:transcriptPath:)`.
    /// Non-Claude tools return nil — only Claude Code writes `away_summary`
    /// records.
    fileprivate func cachedAwaySummary(for session: Session, transcriptPath path: String) -> String? {
        guard session.tool == .claude else { return nil }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let mtime, let cached = transcriptAwaySummaryCache[path], cached.mtime == mtime {
            return cached.summary
        }
        let summary = TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcriptPath: path)
        if let mtime {
            transcriptAwaySummaryCache[path] = (mtime, summary)
        }
        return summary
    }

    /// Scan the session's transcript for the latest in-progress assistant
    /// text, re-using a previous result when the transcript's mtime hasn't
    /// advanced. Mirrors `cachedAwaySummary(for:transcriptPath:)`.
    /// Non-Claude tools return nil — only Claude Code transcripts are
    /// shaped for `TranscriptLatestAssistantScanner`.
    fileprivate func cachedLatestAssistant(for session: Session, transcriptPath path: String) -> String? {
        guard session.tool == .claude else { return nil }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let mtime, let cached = transcriptLatestAssistantCache[path], cached.mtime == mtime {
            return cached.text
        }
        let text = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcriptPath: path)
        if let mtime {
            transcriptLatestAssistantCache[path] = (mtime, text)
        }
        return text
    }

    /// Scan the session's transcript for the model it last used, re-using a
    /// previous result when the transcript's mtime hasn't advanced. Mirrors
    /// `cachedLatestAssistant(for:transcriptPath:)`. Tools without a
    /// transcript return nil inside the scanner, before touching the file.
    fileprivate func cachedModel(for session: Session, transcriptPath path: String) -> String? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let mtime, let cached = transcriptModelCache[path], cached.mtime == mtime {
            return cached.model
        }
        let model = TranscriptModelScanner.extractModel(transcriptPath: path, tool: session.tool)
        if let mtime {
            transcriptModelCache[path] = (mtime, model)
        }
        return model
    }

    /// Drop cache entries for transcripts whose owning session is no longer
    /// listed. Mirrors `pruneTranscriptLatestAssistantCache`.
    fileprivate func pruneTranscriptModelCache(keepingPaths paths: [String]) {
        let live = Set(paths)
        transcriptModelCache = transcriptModelCache.filter { live.contains($0.key) }
    }

    /// The most common display model per agent. Cloud sessions are all
    /// Claude and count toward `.claude`. Ties go to the alphabetically first
    /// name so the highlight doesn't flicker between refreshes.
    nonisolated static func usualModels(
        local: [(SessionTool, String)],
        remote: [String]
    ) -> [SessionTool: String] {
        var counts: [SessionTool: [String: Int]] = [:]
        for (tool, model) in local {
            counts[tool, default: [:]][model, default: 0] += 1
        }
        for raw in remote where !raw.isEmpty {
            counts[.claude, default: [:]][TranscriptModelScanner.displayName(for: raw), default: 0] += 1
        }
        return counts.compactMapValues { byModel in
            byModel.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
        }
    }

    /// The model pill for a local row, or nil when its transcript names no
    /// model.
    public func modelPill(for session: Session) -> ModelPill? {
        guard let name = modelsById[session.id] else { return nil }
        return ModelPill(name: name, isUnusual: isUnusualModel(name, tool: session.tool))
    }

    /// The model pill for a cloud row. Every cloud session is Claude.
    public func modelPill(for remote: RemoteClaudeCodeSession) -> ModelPill? {
        guard !remote.model.isEmpty else { return nil }
        let name = TranscriptModelScanner.displayName(for: remote.model)
        return ModelPill(name: name, isUnusual: isUnusualModel(name, tool: .claude))
    }

    /// Whether `model` differs from the usual model for `tool`, which gets
    /// the pill its highlight. A lone session is its agent's usual model.
    public func isUnusualModel(_ model: String, tool: SessionTool) -> Bool {
        guard let usual = usualModelByTool[tool] else { return false }
        return model != usual
    }

    /// Bytes of transcript the title scanner may read per `refresh()`, shared
    /// across sessions. Resumed scans read only appended bytes, so this only
    /// bites on a cold cache: the 50 listed transcripts can total 100 MB+
    /// (~90 ms in one tick); capped, they fill over a few ticks instead.
    /// Instance-level (not `static`) so tests can shrink it.
    var titleScanBytesPerRefresh = 16 * 1024 * 1024

    /// Scan the session's transcript for its Claude Code title, resuming
    /// from where the previous scan of this path stopped and drawing reads
    /// from the shared per-refresh `budget`. Once the budget is spent, this
    /// returns the cached title without reading. Non-Claude tools return
    /// nil — only Claude Code writes `ai-title` / `custom-title` records.
    fileprivate func cachedTitle(for session: Session, transcriptPath path: String, budget: inout Int) -> String? {
        guard session.tool == .claude else { return nil }
        let previous = transcriptTitleCache[path]
        guard budget > 0 else { return previous?.title }
        guard let state = TranscriptTitleScanner.scan(transcriptPath: path, resuming: previous, maxBytes: budget) else {
            transcriptTitleCache.removeValue(forKey: path)
            return nil
        }
        transcriptTitleCache[path] = state
        // A rewritten (shrunk) file restarts from 0, so count from there.
        let start = previous.map { $0.offset <= state.offset ? $0.offset : 0 } ?? 0
        budget -= Int(state.offset - start)
        return state.title
    }

    /// The Codex thread name for `session`, from the `session_index.jsonl`
    /// beside its rollout. Each index is scanned at most once per refresh:
    /// `scanned` collects this refresh's states, resuming from
    /// `codexThreadNameCache`, and becomes the new cache.
    fileprivate func codexThreadName(
        for session: Session,
        scanned: inout [String: CodexThreadNameIndex.State]
    ) -> String? {
        guard let conversationId = session.conversationId,
              let rolloutPath = session.transcriptPath,
              let indexPath = CodexThreadNameIndex.indexPath(forRolloutPath: rolloutPath)
        else { return nil }
        if scanned[indexPath] == nil {
            scanned[indexPath] = CodexThreadNameIndex.scan(
                indexPath: indexPath, resuming: codexThreadNameCache[indexPath])
        }
        return scanned[indexPath]?.names[conversationId]
    }

    /// Drop cache entries for transcripts whose owning session is no longer
    /// in the live list. Mirrors `pruneTranscriptAwaySummaryCache`.
    fileprivate func pruneTranscriptTitleCache(keepingPaths paths: [String]) {
        let live = Set(paths)
        transcriptTitleCache = transcriptTitleCache.filter { live.contains($0.key) }
    }

    /// Drop cache entries for transcripts whose owning session is no longer
    /// in the live list. Mirrors `pruneTranscriptBridgeCache`.
    fileprivate func pruneTranscriptAwaySummaryCache(keepingPaths paths: [String]) {
        let live = Set(paths)
        transcriptAwaySummaryCache = transcriptAwaySummaryCache.filter { live.contains($0.key) }
    }

    /// Drop cache entries for transcripts whose owning session is no longer
    /// in the live list. Mirrors `pruneTranscriptAwaySummaryCache`.
    fileprivate func pruneTranscriptLatestAssistantCache(keepingPaths paths: [String]) {
        let live = Set(paths)
        transcriptLatestAssistantCache = transcriptLatestAssistantCache.filter { live.contains($0.key) }
    }

    public func markSessionRead(_ session: Session) {
        do {
            try database.markSessionRead(id: session.id)
            unreadSessionIds.remove(session.id)
        } catch {
            // DB write failed; leave unread state unchanged so next refresh re-syncs
        }
    }

    /// Mark the currently selected row as read, whatever its row type.
    /// Local rows go through `Database.markSessionRead`; remote rows go through
    /// `Database.markRemoteClaudeCodeSessionRead`. Either way the in-memory
    /// `unreadSessionIds` set is updated so the row's unread treatment flips
    /// immediately without waiting for a refresh.
    public func markSelectedRowRead() {
        switch selectedRow {
        case .local(let session):
            markSessionRead(session)
        case .remote(let remote):
            do {
                try database.markRemoteClaudeCodeSessionRead(id: remote.id)
                unreadSessionIds.remove(remote.id)
                // Patch the in-memory row too — the next `refresh()` will read
                // the same value back from the DB, but between now and then
                // the panel may re-render (e.g. from another @Published
                // change). Without this, the Unread pill would briefly re-
                // flash because `isUnread` would still see the stale nil.
                if let idx = remoteSessions.firstIndex(where: { $0.id == remote.id }) {
                    remoteSessions[idx].lastReadAt = Date()
                }
            } catch {
                // DB write failed; leave unread state unchanged so next refresh re-syncs
            }
        case .none:
            break
        }
    }

    public func resetSelection() {
        let rows = orderedRows
        if rows.isEmpty {
            selectedIndex = -1
            return
        }
        if let id = lastFocusedSessionId,
           let focusedAt = lastFocusedAt,
           Date().timeIntervalSince(focusedAt) < focusMemoryWindow {
            if let index = rows.firstIndex(where: { $0.id == id && $0.isActive }) {
                selectedIndex = index
                return
            }
        }
        selectedIndex = 0
    }

    public func enterSearch() {
        isSearching = true
        searchQuery = ""
        selectedIndex = 0
        recallErrorMessage = nil
    }

    public func exitSearch() {
        isSearching = false
        searchQuery = ""
        isNavigatingSearch = false
        selectedIndex = 0
        debounceTask?.cancel()
        recallSearchTask?.cancel()
        recallResults = []
        recallErrorMessage = nil
        clearRecallSearchState()
    }

    public func appendSearchCharacter(_ char: String) {
        searchQuery.append(char)
        selectedIndex = 0
        triggerRecallSearch()
    }

    public func deleteSearchCharacter() {
        guard !searchQuery.isEmpty else {
            exitSearch()
            return
        }
        searchQuery.removeLast()
        selectedIndex = 0
        triggerRecallSearch()
    }

    public func deleteSearchWord() {
        guard !searchQuery.isEmpty else {
            exitSearch()
            return
        }
        // Trim trailing whitespace, then remove back to the previous whitespace boundary
        while searchQuery.last?.isWhitespace == true { searchQuery.removeLast() }
        while let last = searchQuery.last, !last.isWhitespace { searchQuery.removeLast() }
        selectedIndex = 0
        triggerRecallSearch()
    }

    public func clearSearchQuery() {
        searchQuery = ""
        selectedIndex = 0
        recallErrorMessage = nil
        triggerRecallSearch()
    }

    // MARK: - Kill process

    /// Liveness check for the kill flow. Injectable so tests never depend on
    /// (or signal) real PIDs.
    var isProcessAlive: (Int) -> Bool = ProcessLiveness.isAlive

    public func requestKill() {
        // Cloud rows: silent no-op with a one-time toast flag flip.
        if case .remote = selectedRow {
            showedCloudKillToast = true
            return
        }
        guard let session = selectedSession, session.isActive else { return }
        pendingKillSessionId = session.id
        pendingKillRemovesRow = !hasLiveProcess(session)
    }

    public func confirmKill() {
        defer { pendingKillSessionId = nil; pendingKillRemovesRow = false }
        guard let killId = pendingKillSessionId,
              let session = sessions.first(where: { $0.id == killId }),
              session.isActive else { return }
        if let pid = session.pid, isProcessAlive(pid) {
            kill(Int32(pid), SIGTERM)
        } else {
            // Nothing left to signal: the process exited without its end hook
            // firing, or no PID was ever recorded. The reaper only ends rows
            // with a dead PID, so a PID-less row would stay active forever.
            try? database.endSession(id: session.id, status: .stale)
        }
        refresh()
    }

    public func cancelKill() {
        pendingKillSessionId = nil
        pendingKillRemovesRow = false
    }

    private func hasLiveProcess(_ session: Session) -> Bool {
        guard let pid = session.pid else { return false }
        return isProcessAlive(pid)
    }

    public func requestFork() {
        // `selectedSession` is local-only — remote Claude rows silently no-op
        // here because they have no host terminal app or launch directory to
        // route the fork through. Adding remote-fork support would need a
        // separate plan to decide cwd + target terminal.
        guard let session = selectedSession, session.tool == .claude else { return }
        pendingForkSessionId = session.id
    }

    public func confirmFork() -> String? {
        let id = pendingForkSessionId
        pendingForkSessionId = nil
        return id
    }

    public func cancelFork() {
        pendingForkSessionId = nil
    }

    /// Reset the one-time cloud-kill toast flag after the view has shown it.
    public func acknowledgeCloudKillToast() {
        showedCloudKillToast = false
    }

    // MARK: - Mark all read

    public func requestMarkAllRead() {
        guard !unreadSessionIds.isEmpty else { return }
        pendingMarkAllRead = true
    }

    public func confirmMarkAllRead() {
        // Best-effort per id: one bad row should not block the rest. Any DB
        // failure is absorbed by `try?`, and the next `refresh()` rebuilds
        // `unreadSessionIds` from the authoritative DB state so we self-heal.
        let remoteIds = Set(remoteSessions.map(\.id))
        var successfullyMarked: Set<String> = []
        for id in unreadSessionIds {
            let ok: Bool
            if remoteIds.contains(id) {
                ok = (try? database.markRemoteClaudeCodeSessionRead(id: id)) != nil
            } else {
                ok = (try? database.markSessionRead(id: id)) != nil
            }
            if ok { successfullyMarked.insert(id) }
        }
        let now = Date()
        for i in remoteSessions.indices where successfullyMarked.contains(remoteSessions[i].id) {
            remoteSessions[i].lastReadAt = now
        }
        unreadSessionIds.subtract(successfullyMarked)
        pendingMarkAllRead = false
    }

    public func cancelMarkAllRead() {
        pendingMarkAllRead = false
    }

    // MARK: - Recall semantic search

    /// Copy a recall result's resume command to the clipboard.
    /// Constructs the compound form (cd + command) so the user can paste and run directly.
    public func copyResumeCommand(_ result: RecallResult) {
        let command = SessionAction.compoundShellCommand(result.resumeCmd, directory: result.project)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
    /// Find any session (active or inactive) matching a recall result's session ID.
    public func session(for result: RecallResult) -> Session? {
        sessions.first { $0.conversationId == result.sessionId }
    }

    private func clearRecallSearchState() {
        isRecallSearching = false
        recallIndexingDone = nil
        recallIndexingTotal = nil
    }

    private func triggerRecallSearch() {
        debounceTask?.cancel()
        recallSearchTask?.cancel()

        let query = searchQuery
        guard !query.isEmpty else {
            recallResults = []
            recallErrorMessage = nil
            isRecallSearching = false
            return
        }

        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.executeRecallSearch(query: query)
        }
    }

    private var recallSearchGeneration: Int = 0

    /// Test seam: replace to inject canned recall outcomes.
    internal var recallSearchProvider: @Sendable (String, (@Sendable (Int, Int) -> Void)?) async throws -> RecallSearchResponse = { query, onIndexing in
        try await RecallService.search(query: query, onIndexing: onIndexing)
    }

    private static func firstLine(_ s: String, maxLength: Int = 200) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? trimmed
        if line.count > maxLength {
            let idx = line.index(line.startIndex, offsetBy: maxLength)
            return String(line[..<idx]) + "…"
        }
        return line
    }

    private func executeRecallSearch(query: String) {
        isRecallSearching = true
        recallResults = []
        recallErrorMessage = nil
        recallIndexingDone = nil
        recallIndexingTotal = nil
        recallSearchGeneration += 1
        let searchGen = recallSearchGeneration

        recallSearchTask = Task { @MainActor [weak self] in
            do {
                let onIndexing: @Sendable (Int, Int) -> Void = { [weak self] done, total in
                    Task { @MainActor [weak self] in
                        guard self?.recallSearchGeneration == searchGen else { return }
                        self?.recallIndexingDone = done
                        self?.recallIndexingTotal = total
                    }
                }
                guard let provider = self?.recallSearchProvider else { return }
                let response = try await provider(query, onIndexing)
                guard !Task.isCancelled else { return }
                // Filter out recall hits for sessions we're already showing as local rows.
                let shownIds = Set((self?.orderedRows ?? []).compactMap { row -> String? in
                    if case .local(let session) = row { return session.conversationId } else { return nil }
                })
                self?.recallResults = response.results.filter { !shownIds.contains($0.sessionId) }
                self?.recallGeneration += 1
                self?.clearRecallSearchState()
            } catch let recallError as RecallError {
                guard !Task.isCancelled else { return }
                switch recallError {
                case .notInstalled:
                    // Unreachable in v0.5.0+ (native recall is always
                    // available). Surface defensively as an error message
                    // so a future regression doesn't fall through silently.
                    self?.recallErrorMessage = "Semantic search unavailable"
                case .timeout:
                    self?.recallErrorMessage = "Semantic search timed out"
                case .searchFailed(let msg):
                    let cleaned = msg.replacingOccurrences(
                        of: "^recall exited with status \\d+: ",
                        with: "",
                        options: .regularExpression
                    )
                    self?.recallErrorMessage = "Semantic search failed: \(Self.firstLine(cleaned))"
                }
                self?.clearRecallSearchState()
            } catch {
                guard !Task.isCancelled else { return }
                self?.recallErrorMessage = "Semantic search failed: \(Self.firstLine(error.localizedDescription))"
                self?.clearRecallSearchState()
            }
        }
    }
}
