import SwiftUI
import SeshctlCore

public struct SessionListView: View {
    @ObservedObject var viewModel: SessionListViewModel
    @ObservedObject var connectionStore: ClaudeCodeConnectionStore
    @StateObject private var hostAppResolver = HostAppResolver()
    @State private var showingSettings = false
    var onSessionTap: ((Session) -> Void)?
    var onOpenDetail: ((Session) -> Void)?
    /// Handler for opening a bridged local row's claude.ai twin. Supplied by
    /// `AppDelegate`; nil in previews/tests leaves the cloud glyph static.
    var onOpenWeb: ((Session) -> Void)?
    var onOpenRecallDetail: ((RecallResult, Session?) -> Void)?
    /// Plumbed through to `SettingsPopover` so the triple-dot menu can offer
    /// Uninstall/Quit actions matching the status bar menu. Supplied by
    /// `AppDelegate`; left nil for previews/tests so the section hides.
    var onUninstall: (() -> Void)?
    /// Plumbed through to `SettingsPopover` so the triple-dot menu's Editor
    /// Integrations section can open the same window the post-install flow
    /// shows. Supplied by `AppDelegate`; nil in previews/tests hides the
    /// section.
    var onOpenIntegrations: (() -> Void)?
    /// Plumbed through to `SettingsPopover` so the triple-dot menu's About
    /// section can offer a manual Sparkle update check. Supplied by
    /// `AppDelegate`; nil in previews/tests hides the button.
    var onCheckForUpdates: (() -> Void)?
    var onQuit: (() -> Void)?

    private static let firstOpenAnimationGate: TimeInterval = 0.5

    public init(
        viewModel: SessionListViewModel,
        connectionStore: ClaudeCodeConnectionStore,
        onSessionTap: ((Session) -> Void)? = nil,
        onOpenDetail: ((Session) -> Void)? = nil,
        onOpenWeb: ((Session) -> Void)? = nil,
        onOpenRecallDetail: ((RecallResult, Session?) -> Void)? = nil,
        onUninstall: (() -> Void)? = nil,
        onOpenIntegrations: (() -> Void)? = nil,
        onCheckForUpdates: (() -> Void)? = nil,
        onQuit: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.connectionStore = connectionStore
        self.onSessionTap = onSessionTap
        self.onOpenDetail = onOpenDetail
        self.onOpenWeb = onOpenWeb
        self.onOpenRecallDetail = onOpenRecallDetail
        self.onUninstall = onUninstall
        self.onOpenIntegrations = onOpenIntegrations
        self.onCheckForUpdates = onCheckForUpdates
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Seshctl")
                    .font(.system(.title2, design: .monospaced, weight: .bold))
                Spacer()
                if viewModel.sourceFilter != .all {
                    Text(filterBadgeText(viewModel.sourceFilter))
                        .font(.system(.footnote, design: .monospaced, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                }
                Text("\(viewModel.activeRows.count) active")
                    .font(.body)
                    .foregroundStyle(.secondary)
                if connectionStore.hasClaudeConnection && viewModel.remoteSessionCount > 0 {
                    Text("·")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 4) {
                        Image(systemName: "icloud.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Text("\(viewModel.remoteSessionCount) remote")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .help("Sessions currently active on claude.ai.")
                }
                Button {
                    viewModel.showingHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(.title3))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Help")
                .popover(isPresented: $viewModel.showingHelp, arrowEdge: .top) {
                    HelpPopover()
                }
                Button {
                    showingSettings.toggle()
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(.title3))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .keyboardShortcut(",", modifiers: .command)
                .popover(isPresented: $showingSettings, arrowEdge: .top) {
                    SettingsPopover(
                        store: connectionStore,
                        onUninstall: onUninstall,
                        onQuit: onQuit,
                        onOpenIntegrations: onOpenIntegrations,
                        onCheckForUpdates: onCheckForUpdates
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            SignInBanner(store: connectionStore)

            if viewModel.isSearching {
                SearchBar(query: viewModel.searchQuery, isActive: !viewModel.isNavigatingSearch) {
                    Text(viewModel.isNavigatingSearch
                         ? "shift-tab to edit · esc to close"
                         : "tab to navigate · esc to close")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            if let error = viewModel.error {
                Text(error)
                    .font(.body)
                    .foregroundStyle(.red)
                    .padding()
            } else if let kind = viewModel.emptyState {
                // Routing policy lives on the viewmodel
                // (`SessionListViewModel.emptyState`) so it can be unit-
                // tested independently. The recents-only state was
                // originally added in PR #32 review S3.
                switch kind {
                case .fullyEmpty:
                    emptyStateView(
                        headline: "No sessions",
                        subtext: "Start a Claude/Gemini/Codex session to see it here."
                    )
                case .recentsOnly:
                    emptyStateView(
                        headline: "No active sessions",
                        subtext: "Press / to find recent sessions."
                    )
                case .filteredOut:
                    emptyStateView(
                        headline: "No \(filterShortNoun(viewModel.sourceFilter)) sessions",
                        subtext: "Press r to change filter."
                    )
                }
            } else if viewModel.isTreeMode && !viewModel.isSearching {
                SessionTreeView(
                    viewModel: viewModel,
                    connectionStore: connectionStore,
                    onSessionTap: onSessionTap,
                    onOpenDetail: onOpenDetail,
                    onOpenWeb: onOpenWeb
                )
            } else {
                let ordered = viewModel.orderedRows
                let activeCount = viewModel.activeRows.count
                // Compute once per body pass — `hasMultipleAgentTypes`
                // walks `orderedRows`; lifting it out of the per-row
                // ViewBuilder avoids O(rows) walks per layout.
                let showAgentBadge = viewModel.hasMultipleAgentTypes

                // activeRows is sorted by sortTimestamp DESC so buckets appear
                // in calendar-day order.
                let now = Date()
                let activeBuckets: [SessionAgeDisplay.AgeBucket] = (0..<activeCount).map { idx in
                    SessionAgeDisplay(timestamp: ordered[idx].sortTimestamp, now: now).bucket
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, row in
                                if index < activeCount {
                                    let bucket = activeBuckets[index]
                                    let isFirstOfBucket = index == 0 || activeBuckets[index - 1] != bucket
                                    if isFirstOfBucket {
                                        // Bucket headers only appear above active sessions; closed sessions render under the "Recent" header below.
                                        sectionHeader(bucket.displayName)
                                    }
                                } else if index == activeCount && activeCount > 0 {
                                    sectionHeader("Recent")
                                }

                                let isSelected = index == viewModel.selectedIndex
                                let isRowActive = row.isActive

                                rowView(for: row, showAgentBadge: showAgentBadge)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        viewModel.selectedIndex = index
                                        if case .local(let session) = row {
                                            onSessionTap?(session)
                                        }
                                    }
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isSelected
                                                ? Color.accentColor.opacity(0.2)
                                                : Color.clear)
                                    )
                                    .opacity(rowOpacity(isActive: isRowActive, isSelected: isSelected))
                                    .id(rowViewIdentity(for: row))
                            }

                            if activeCount == 0 && !ordered.isEmpty {
                                sectionHeader("Recent")
                                    .padding(.top, -4) // adjust since ForEach won't insert it
                            }

                            // Semantic search section
                            if viewModel.isSearching {
                                if viewModel.isRecallSearching {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Group {
                                            if let total = viewModel.recallIndexingTotal {
                                                if let done = viewModel.recallIndexingDone, done > 0 {
                                                    Text("Indexing \(done)/\(total) entries...")
                                                } else {
                                                    Text("Indexing \(total) entries...")
                                                }
                                            } else {
                                                Text("Searching...")
                                            }
                                        }
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                }

                                if !viewModel.recallResults.isEmpty {
                                    sectionHeader("Semantic")

                                    ForEach(Array(viewModel.recallResults.enumerated()), id: \.element.id) { recallIndex, result in
                                        let globalIndex = ordered.count + recallIndex
                                        let isSelected = globalIndex == viewModel.selectedIndex
                                        let matchedSession = viewModel.session(for: result)

                                        RecallResultRowView(
                                            result: result,
                                            isActive: matchedSession?.isActive ?? false,
                                            hostApp: matchedSession.map { hostAppResolver.resolve(session: $0) },
                                            searchQuery: viewModel.searchQuery,
                                            onDetail: onOpenRecallDetail.map { handler in
                                                {
                                                    if let session = matchedSession {
                                                        viewModel.markSessionRead(session)
                                                    }
                                                    handler(result, matchedSession)
                                                }
                                            }
                                        )
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            viewModel.selectedIndex = globalIndex
                                        }
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(isSelected
                                                    ? Color.accentColor.opacity(0.2)
                                                    : Color.clear)
                                        )
                                        .opacity(isSelected ? 0.9 : 0.6)
                                        .id("recall-\(viewModel.recallGeneration)-\(recallIndex)")
                                    }
                                }

                                if let errorMessage = viewModel.recallErrorMessage {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundStyle(.orange)
                                        Text(errorMessage)
                                            .font(.system(.footnote, design: .monospaced))
                                            .foregroundStyle(.orange)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        // Suppress the reorder spring for the first ~half-second
                        // after the panel opens — the immediate `refresh()` in
                        // `panelDidShow()` would otherwise spring every row into
                        // its new position on every reopen.
                        .animation(
                            Date().timeIntervalSince(viewModel.lastPanelShownAt) > Self.firstOpenAnimationGate
                                ? .spring(response: 0.32, dampingFraction: 0.86)
                                : nil,
                            value: ordered.map(\.id)
                        )
                    }
                    .followSelectionScroll(
                        ordered: ordered,
                        selectedIndex: viewModel.selectedIndex,
                        proxy: proxy
                    )
                    .onChange(of: viewModel.selectedIndex) { newIndex in
                        guard viewModel.isSearching, newIndex >= ordered.count else { return }
                        let recallIndex = newIndex - ordered.count
                        if recallIndex >= 0 && recallIndex < viewModel.recallResults.count {
                            withAnimation(.easeOut(duration: 0.02)) {
                                proxy.scrollTo("recall-\(viewModel.recallGeneration)-\(recallIndex)", anchor: .center)
                            }
                        }
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                if viewModel.pendingKillSessionId != nil {
                    Text("kill process? y/n")
                        .foregroundStyle(.red)
                } else if viewModel.pendingForkSessionId != nil {
                    Text("fork session? y/n")
                        .foregroundStyle(Color.accentColor)
                } else if viewModel.pendingMarkAllRead {
                    Text("mark all as read? y/n")
                        .foregroundStyle(.orange)
                } else {
                    Text("enter focus · w web · f fork · / search · ? help · q close")
                }
            }
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Header badge text for the active source filter.
    private func filterBadgeText(_ filter: SessionListViewModel.SourceFilter) -> String {
        switch filter {
        case .all: return "all"
        case .localOnly: return "local only"
        case .remoteOnly: return "remote only"
        }
    }

    /// Short noun for the active source filter, used in empty-state copy
    /// like "No remote sessions". The header badge keeps the "only"
    /// qualifier; this slot reads more naturally without it.
    private func filterShortNoun(_ filter: SessionListViewModel.SourceFilter) -> String {
        switch filter {
        case .all: return "matching" // unreachable: `.filteredOut` only fires when filter != .all
        case .localOnly: return "local"
        case .remoteOnly: return "remote"
        }
    }

    /// Centered empty-state block that expands to fill the panel so the
    /// outer `VStack` doesn't vertically center its remaining content
    /// (which would drift the header to the middle).
    @ViewBuilder
    private func emptyStateView(headline: String, subtext: String) -> some View {
        VStack(spacing: 8) {
            Text(headline)
                .font(.body)
                .foregroundStyle(.secondary)
            Text(subtext)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Renders the row content for a `DisplayRow`. Local rows use the
    /// existing `SessionRowView`; remote rows use `RemoteClaudeCodeRowView`.
    /// `showAgentBadge` is computed once at the parent body — see the
    /// note in `body` — and passed down so this builder doesn't re-walk
    /// `orderedRows` per row.
    @ViewBuilder
    private func rowView(for row: DisplayRow, showAgentBadge: Bool) -> some View {
        switch row {
        case .local(let session):
            SessionRowView(
                session: session,
                hostApp: hostAppResolver.resolve(session: session),
                isUnread: viewModel.unreadSessionIds.contains(session.id),
                isBridged: viewModel.bridgedLocalIds.contains(session.id),
                showCloudAffordances: connectionStore.hasClaudeConnection,
                showAgentBadge: showAgentBadge,
                awaySummary: viewModel.awaySummariesById[session.id] ?? viewModel.latestAssistantById[session.id],
                // List view has a Yesterday section header, so the per-row
                // slot shows the more specific clock time for yesterday rows
                // instead of repeating the day.
                yesterdayStyle: .timeOfDay,
                onDetail: onOpenDetail.map { handler in
                    {
                        viewModel.markSessionRead(session)
                        handler(session)
                    }
                },
                // Only bridged rows get a live handler — an unbridged local has
                // no web twin, and the glyph isn't rendered for it anyway.
                onOpenWeb: viewModel.bridgedLocalIds.contains(session.id)
                    ? onOpenWeb.map { handler in { handler(session) } }
                    : nil
            )
        case .remote(let remote):
            RemoteClaudeCodeRowView(
                session: remote,
                isSelected: viewModel.selectedRow?.id == remote.id,
                isUnread: viewModel.unreadSessionIds.contains(remote.id),
                isStale: connectionStore.state == .authExpired,
                showAgentBadge: showAgentBadge,
                awaySummary: connectionStore.remoteAwaySummariesById[remote.id],
                yesterdayStyle: .timeOfDay
            )
        }
    }

    private func rowOpacity(isActive: Bool, isSelected: Bool) -> Double {
        let searchTyping = viewModel.isSearching && !viewModel.isNavigatingSearch
        if searchTyping {
            return isSelected ? 0.8 : 0.5
        }
        return isActive || isSelected ? 1.0 : 0.7
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}
