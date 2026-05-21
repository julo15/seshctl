import AppKit
import Combine
import Darwin
import Foundation
import SeshctlCore

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
    /// Latest Claude Code `away_summary` ("recap") per local session, keyed by
    /// `session.id`. Sessions without a recap are absent (the row falls
    /// through to its existing preview chain). Computed in `refresh()` via
    /// `TranscriptAwaySummaryScanner` with `transcriptAwaySummaryCache`
    /// providing mtime-based reuse so re-reads of unchanged transcripts are
    /// skipped on the 2-second refresh cadence.
    @Published public private(set) var awaySummariesById: [String: String] = [:]
    /// Per-transcript cache: `path → (mtime, cseId)`. Lets `refresh()` skip
    /// re-reading a live Claude transcript when its file mtime hasn't
    /// advanced. Bounded by `sessions.count` on each refresh (entries for
    /// paths no longer present in the session list are evicted).
    private var transcriptBridgeCache: [String: (mtime: Date, cseId: String?)] = [:]
    /// Per-transcript cache: `path → (mtime, awaySummary)`. Mirrors
    /// `transcriptBridgeCache` for Claude Code recaps. Pruned by
    /// `pruneTranscriptAwaySummaryCache(keepingPaths:)` on each refresh.
    private var transcriptAwaySummaryCache: [String: (mtime: Date, summary: String?)] = [:]
    @Published public private(set) var recallResults: [RecallResult] = []
    @Published public private(set) var isRecallSearching: Bool = false
    @Published public private(set) var recallIndexingDone: Int?
    @Published public private(set) var recallIndexingTotal: Int?
    @Published public private(set) var recallUnavailable: Bool = false
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

    /// Source filter. `didSet` persists to UserDefaults (not `@AppStorage`
    /// for the same reason as `isTreeMode`).
    @Published public var sourceFilter: SourceFilter {
        didSet {
            defaults.set(sourceFilter.rawValue, forKey: Self.sourceFilterDefaultsKey)
        }
    }

    public init(database: SeshctlDatabase, refreshInterval: TimeInterval = 2.0, enableGC: Bool = true, focusMemoryWindow: TimeInterval = 30, defaults: UserDefaults = .standard) {
        self.database = database
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
        refresh()
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
            if enableGC {
                try database.reapStaleSessions()
            }
            if enableGC && Date().timeIntervalSince(lastGC) > gcInterval {
                try database.gc(olderThan: 30 * 24 * 3600)
                lastGC = Date()
            }
            sessions = try database.listSessions(limit: 50)
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
            // Compute bridged pairs (local CLI session ↔ remote claude.ai
            // `environment_kind == "bridge"` session) by reading each live
            // Claude local's transcript for a `bridge_status` event, which
            // carries the claude.ai session URL deterministically. Hides
            // the remote twin from the list and marks the local twin for
            // a cloud badge.
            let pairs = BridgeMatcher.match(
                locals: sessions,
                remotes: remoteSessions,
                bridgedRemoteId: { [weak self] session in
                    self?.cachedBridgedRemoteId(for: session)
                }
            )
            bridgedLocalIds = Set(pairs.map(\.localId))
            bridgedRemoteIds = Set(pairs.map(\.remoteId))
            // Pull the latest Claude Code `away_summary` per local Claude session
            // into `awaySummariesById`. Reuses the per-transcript mtime cache to
            // skip re-reading unchanged JSONLs. Non-Claude tools are guarded inside
            // `cachedAwaySummary(for:)` and never hit the filesystem.
            var summaries: [String: String] = [:]
            for session in sessions {
                if let summary = cachedAwaySummary(for: session) {
                    summaries[session.id] = summary
                }
            }
            awaySummariesById = summaries
            let livePaths = sessions.compactMap(\.transcriptPath)
            pruneTranscriptAwaySummaryCache(keepingPaths: livePaths)
            pruneTranscriptBridgeCache(keepingPaths: livePaths)
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
        let query = searchQuery.lowercased()
        return sessions.filter { session in
            session.directory.lowercased().contains(query)
                || (session.gitRepoName?.lowercased().contains(query) ?? false)
                || (session.gitBranch?.lowercased().contains(query) ?? false)
                || (session.lastAsk?.lowercased().contains(query) ?? false)
                || (session.lastReply?.lowercased().contains(query) ?? false)
                || session.tool.rawValue.lowercased().contains(query)
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
        let query = searchQuery.lowercased()
        return remoteSessions.filter { remote in
            let titleHit = remote.title.lowercased().contains(query)
            let repoHit = (DisplayRow.repoShortName(from: remote.repoUrl)?.lowercased().contains(query)) ?? false
            let branchesHit = remote.branches.joined(separator: " ").lowercased().contains(query)
            return titleHit || repoHit || branchesHit
        }
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
        return (localActive + remoteActive).sorted { $0.sortTimestamp > $1.sortTimestamp }
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
        return (localRecent + remoteRecent).sorted { $0.sortTimestamp > $1.sortTimestamp }
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
        if isTreeMode {
            return treeOrderedRows
        }
        if isSearching {
            return activeRows + recentRows
        }
        return activeRows
    }

    /// Ordered rows the view renders. Matches `filteredRows`; retained as
    /// a separate name to keep intent clear at call sites.
    public var orderedRows: [DisplayRow] { filteredRows }

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
            let sorted = (buckets[key] ?? []).sorted { $0.sortTimestamp > $1.sortTimestamp }
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
        guard isTreeMode else { return }
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
        guard isTreeMode else { return }
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

    /// Scan `session.transcriptPath` for a `bridge_status` cse_id, re-using a
    /// previous result when the transcript's mtime hasn't advanced. Non-Claude
    /// tools return nil without a filesystem hit — Codex/Gemini transcripts
    /// can't contain a Claude bridge event, and skipping them avoids multi-MB
    /// reads on every 2-second refresh.
    fileprivate func cachedBridgedRemoteId(for session: Session) -> String? {
        guard session.tool == .claude else { return nil }
        guard let path = session.transcriptPath else { return nil }
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

    /// Scan `session.transcriptPath` for the latest `away_summary` content,
    /// re-using a previous result when the transcript's mtime hasn't
    /// advanced. Mirrors `cachedBridgedRemoteId(for:)`. Non-Claude tools
    /// return nil without a filesystem hit — only Claude Code writes
    /// `away_summary` records.
    fileprivate func cachedAwaySummary(for session: Session) -> String? {
        guard session.tool == .claude else { return nil }
        guard let path = session.transcriptPath else { return nil }
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

    /// Drop cache entries for transcripts whose owning session is no longer
    /// in the live list. Mirrors `pruneTranscriptBridgeCache`.
    fileprivate func pruneTranscriptAwaySummaryCache(keepingPaths paths: [String]) {
        let live = Set(paths)
        transcriptAwaySummaryCache = transcriptAwaySummaryCache.filter { live.contains($0.key) }
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
    }

    public func exitSearch() {
        isSearching = false
        searchQuery = ""
        isNavigatingSearch = false
        selectedIndex = 0
        debounceTask?.cancel()
        recallSearchTask?.cancel()
        recallResults = []
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
        triggerRecallSearch()
    }

    // MARK: - Kill process

    public func requestKill() {
        // Cloud rows: silent no-op with a one-time toast flag flip.
        if case .remote = selectedRow {
            showedCloudKillToast = true
            return
        }
        guard let session = selectedSession, session.isActive, session.pid != nil else { return }
        pendingKillSessionId = session.id
    }

    public func confirmKill() {
        guard let killId = pendingKillSessionId,
              let session = sessions.first(where: { $0.id == killId }),
              session.isActive,
              let pid = session.pid else {
            pendingKillSessionId = nil
            return
        }
        kill(Int32(pid), SIGTERM)
        pendingKillSessionId = nil
        refresh()
    }

    public func cancelKill() {
        pendingKillSessionId = nil
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

    private func executeRecallSearch(query: String) {
        guard !recallUnavailable else { return }
        isRecallSearching = true
        recallResults = []
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
                let response = try await RecallService.search(query: query, onIndexing: onIndexing)
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
                if case .notInstalled = recallError {
                    self?.recallUnavailable = true
                }
                self?.clearRecallSearchState()
            } catch {
                guard !Task.isCancelled else { return }
                self?.clearRecallSearchState()
            }
        }
    }
}
