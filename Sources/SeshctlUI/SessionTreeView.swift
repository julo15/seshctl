import SwiftUI
import SeshctlCore

struct SessionTreeView: View {
    @ObservedObject var viewModel: SessionListViewModel
    @ObservedObject var connectionStore: ClaudeCodeConnectionStore
    @StateObject private var hostAppResolver = HostAppResolver()
    var onSessionTap: ((Session) -> Void)?
    var onOpenDetail: ((Session) -> Void)?

    init(
        viewModel: SessionListViewModel,
        connectionStore: ClaudeCodeConnectionStore,
        onSessionTap: ((Session) -> Void)? = nil,
        onOpenDetail: ((Session) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.connectionStore = connectionStore
        self.onSessionTap = onSessionTap
        self.onOpenDetail = onOpenDetail
    }

    var body: some View {
        let ordered = viewModel.treeOrderedRows
        // Compute once per body pass — `hasMultipleAgentTypes` walks
        // `orderedRows`; lifting it out of the per-row ViewBuilder
        // avoids O(rows) walks per layout.
        let showAgentBadge = viewModel.hasMultipleAgentTypes

        ScrollViewReader { proxy in
            ScrollView {
                // LazyVStack intentional — tree mode doesn't animate reorders
                // (the row-rearrange animation is opt-in on the time-sorted
                // list view in `SessionListView`). Row identity is stable
                // across status changes for free since the `rowViewIdentity`
                // refactor.
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.treeGroups) { group in
                        GroupHeaderView(name: group.name, count: group.rows.count, isRepo: group.isRepo)
                            .id(group.id)

                        ForEach(group.rows, id: \.id) { row in
                            let index = ordered.firstIndex(where: { $0.id == row.id }) ?? -1
                            let isSelected = index >= 0 && index == viewModel.selectedIndex
                            let isActive = row.isActive

                            rowView(for: row, showAgentBadge: showAgentBadge)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if index >= 0 {
                                        viewModel.selectedIndex = index
                                    }
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
                                .opacity(isActive || isSelected ? 1.0 : 0.7)
                                .id(rowViewIdentity(for: row))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .followSelectionScroll(
                ordered: ordered,
                selectedIndex: viewModel.selectedIndex,
                proxy: proxy
            )
        }
    }

    /// Renders a tree-view row for a `DisplayRow`. Local rows use
    /// `SessionRowView`; remote rows use `RemoteClaudeCodeRowView`.
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
                model: viewModel.modelsById[session.id],
                isTitling: viewModel.titlingInFlight.contains(session.id),
                // Tree view has no time-based section headers, so the age
                // slot does the day-context work itself via relative-day
                // shorthand ("1d") for yesterday.
                yesterdayStyle: .relativeDay,
                onDetail: onOpenDetail.map { handler in
                    {
                        viewModel.markSessionRead(session)
                        handler(session)
                    }
                }
            )
        case .remote(let remote):
            RemoteClaudeCodeRowView(
                session: remote,
                isSelected: viewModel.selectedRow?.id == remote.id,
                isUnread: viewModel.unreadSessionIds.contains(remote.id),
                isStale: connectionStore.state == .authExpired,
                showAgentBadge: showAgentBadge,
                awaySummary: connectionStore.remoteAwaySummariesById[remote.id],
                yesterdayStyle: .relativeDay
            )
        }
    }
}

private struct GroupHeaderView: View {
    let name: String
    let count: Int
    let isRepo: Bool

    @AppStorage(AppearanceDefaults.repoAccentBarKey) private var repoAccentBarEnabled: Bool = AppearanceDefaults.repoAccentBarDefault

    var body: some View {
        HStack(spacing: 6) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
            }
            Text(name)
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// Dot color for the group header. Returns `nil` to hide the dot
    /// entirely when:
    ///   - the toggle is off (consistent with rows, which hide the
    ///     accent bar rather than falling back to grey), or
    ///   - the group is a synthetic non-repo bucket (e.g. "Cloud — no
    ///     repo") where a confident repo-color dot would be misleading.
    private var dotColor: Color? {
        guard repoAccentBarEnabled, isRepo else { return nil }
        return repoAccentColor(for: name)
    }
}
