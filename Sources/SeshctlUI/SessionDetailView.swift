import SwiftUI
import SeshctlCore

public struct SessionDetailView: View {
    @ObservedObject var viewModel: SessionDetailViewModel

    @AppStorage(AppearanceDefaults.repoAccentBarKey) private var repoAccentBarEnabled: Bool = AppearanceDefaults.repoAccentBarDefault

    public init(viewModel: SessionDetailViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(viewModel.displayName)
                    .font(.system(.title2, design: .monospaced, weight: .bold))
                if let dirLabel = viewModel.directoryLabel {
                    Text("·")
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(dirLabel)
                        .font(.system(.title2, design: .monospaced, weight: .medium))
                        .foregroundStyle(dirLabelColor)
                }
                if let branch = viewModel.gitBranch {
                    Text("·")
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(branch)
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(branchColor)
                }
                Spacer()
                Text(viewModel.toolName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Search bar
            if viewModel.isSearching || !viewModel.searchMatches.isEmpty {
                SearchBar(query: viewModel.searchQuery, isActive: viewModel.isSearching) {
                    if !viewModel.searchMatches.isEmpty {
                        Text("\(viewModel.currentMatchIndex + 1)/\(viewModel.searchMatches.count)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else if !viewModel.searchQuery.isEmpty {
                        Text("no matches")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Content
            if viewModel.isLoading {
                Spacer()
                ProgressView()
                    .progressViewStyle(.circular)
                Spacer()
            } else if let error = viewModel.error {
                Spacer()
                Text(error)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            } else if viewModel.turns.isEmpty {
                Spacer()
                Text("No messages")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            Color.clear.frame(height: 1).id("top-anchor")

                            ForEach(viewModel.displayItems) { item in
                                Group {
                                    switch item {
                                    case .userTurn(let turn):
                                        if case .userMessage(let text, _) = turn {
                                            UserTurnView(
                                                text: text,
                                                isSearchActive: viewModel.isSearchActive,
                                                highlightText: viewModel.isSearchActive ? viewModel.searchQuery : nil,
                                                currentMatchRange: viewModel.currentMatchRange(for: turn.id)
                                            )
                                        }
                                    case .assistantTurn(let turn):
                                        if case .assistantMessage(let text, _, _) = turn {
                                            AssistantTurnView(
                                                text: text,
                                                isSearchActive: viewModel.isSearchActive,
                                                highlightText: viewModel.isSearchActive ? viewModel.searchQuery : nil,
                                                currentMatchRange: viewModel.currentMatchRange(for: turn.id)
                                            )
                                        }
                                    case .collapsedToolBlock(let turns, let counts):
                                        CollapsedToolBlockView(turns: turns, counts: counts)
                                    case .awaySummaryTurn(let turn):
                                        if case .awaySummary(let text, _) = turn {
                                            AwaySummaryTurnView(
                                                text: text,
                                                isSearchActive: viewModel.isSearchActive,
                                                highlightText: viewModel.isSearchActive ? viewModel.searchQuery : nil,
                                                currentMatchRange: viewModel.currentMatchRange(for: turn.id)
                                            )
                                        }
                                    }
                                }
                                .id(item.id)
                            }

                            Color.clear.frame(height: 1).id("bottom-anchor")
                        }
                    }
                    .onAppear {
                        // Start at bottom
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                    .onChange(of: viewModel.scrollCommand) { command in
                        guard let command else { return }
                        handleScroll(command: command, proxy: proxy)
                        viewModel.scrollCommand = nil
                    }
                    .onChange(of: viewModel.scrollToTurnId) { turnId in
                        guard let turnId else { return }
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(turnId, anchor: viewModel.scrollAnchor)
                        }
                        viewModel.scrollToTurnId = nil
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text("q/esc back · j/k scroll · ^f/^b page · G/gg end/top · / search · n/N next/prev")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleScroll(command: SessionDetailViewModel.ScrollCommand, proxy: ScrollViewProxy) {
        // For top/bottom we can use anchors directly.
        // For line/page scrolling, we find the NSScrollView and adjust pixel offsets.
        switch command {
        case .top:
            withAnimation(.easeOut(duration: 0.05)) {
                proxy.scrollTo("top-anchor", anchor: .top)
            }
        case .bottom:
            withAnimation(.easeOut(duration: 0.05)) {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        case .lineDown, .lineUp, .halfPageDown, .halfPageUp, .pageDown, .pageUp:
            scrollByPixels(command: command)
        }
    }

    /// Access the underlying NSScrollView and scroll by pixel offset.
    private func scrollByPixels(command: SessionDetailViewModel.ScrollCommand) {
        guard let scrollView = findScrollView() else { return }
        let clipView = scrollView.contentView
        let visibleHeight = clipView.bounds.height
        let currentY = clipView.bounds.origin.y
        let maxY = (scrollView.documentView?.frame.height ?? 0) - visibleHeight

        let delta: CGFloat
        switch command {
        case .lineDown: delta = 20
        case .lineUp: delta = -20
        case .halfPageDown: delta = visibleHeight / 2
        case .halfPageUp: delta = -(visibleHeight / 2)
        case .pageDown: delta = visibleHeight
        case .pageUp: delta = -visibleHeight
        default: return
        }

        let newY = min(max(currentY + delta, 0), max(maxY, 0))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            clipView.animator().setBoundsOrigin(NSPoint(x: 0, y: newY))
        }
    }

    /// Walk the NSView hierarchy to find the NSScrollView backing SwiftUI's ScrollView.
    private func findScrollView() -> NSScrollView? {
        guard let window = NSApp.keyWindow else { return nil }
        return findScrollViewIn(window.contentView)
    }

    private func findScrollViewIn(_ view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let sv = view as? NSScrollView { return sv }
        for sub in view.subviews {
            if let found = findScrollViewIn(sub) { return found }
        }
        return nil
    }

    /// Accent color for the worktree/dir label in the header — mirrors the
    /// treatment used in `SessionRowView`. Falls back to the historic cyan
    /// tint when repo coloring is off or no accent color is derivable.
    private var dirLabelColor: Color {
        if repoAccentBarEnabled, let color = repoAccentColor(for: viewModel.gitRepoName) {
            return color
        }
        return .cyan.opacity(0.7)
    }

    /// Branch color — tints with the repo accent only when no dir label
    /// is shown. With two accent tokens in a row the emphasis becomes
    /// noisy, so the dir label wins and branch stays `.secondary`.
    private var branchColor: Color {
        if viewModel.directoryLabel != nil { return .secondary }
        if repoAccentBarEnabled, let color = repoAccentColor(for: viewModel.gitRepoName) {
            return color
        }
        return .secondary
    }
}

