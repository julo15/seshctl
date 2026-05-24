import SwiftUI
import SeshctlCore

public struct SessionRowView: View {
    let session: Session
    let hostApp: HostAppInfo
    var isUnread: Bool = false
    /// True when this CLI session is also visible as a bridged claude.ai
    /// Code-tab session. When true, line 2 shows a `cloud.fill` glyph next
    /// to the always-present `laptopcomputer` marker — forming the "laptop +
    /// cloud" variant of the three-way row-kind taxonomy (local-only, bridged,
    /// pure-remote). Gated by `ClaudeCodeConnectionStore.hasClaudeConnection`
    /// — when the user has not connected claude.ai, line 2 shows no row-kind
    /// glyph at all.
    var isBridged: Bool = false
    /// True when the claude.ai connection is active (or previously-active).
    /// When false, line 2 suppresses the `laptopcomputer` and `cloud.fill`
    /// row-kind glyphs entirely — users who haven't connected claude.ai see
    /// the pre-cloud layout with no extra chrome.
    var showCloudAffordances: Bool = false
    /// Whether to render the agent-kind corner badge over the host-app
    /// icon. Suppressed when the visible row list only contains a single
    /// agent kind, since the badge is redundant in that case. Driven by
    /// `SessionListViewModel.hasMultipleAgentTypes`.
    var showAgentBadge: Bool = true
    /// Latest `away_summary` ("recap") for this session, if Claude Code has
    /// written one to the local JSONL. When non-nil, the row's preview slot
    /// shows the recap instead of `lastReply`/`lastAsk`/statusHint — see
    /// `Session.previewContent(awaySummary:)`. Sourced from
    /// `SessionListViewModel.awaySummariesById`.
    var awaySummary: String? = nil

    var onDetail: (() -> Void)?

    @AppStorage(AppearanceDefaults.repoAccentBarKey) private var repoAccentBarEnabled: Bool = AppearanceDefaults.repoAccentBarDefault
    @AppStorage(AppearanceDefaults.stackedRowLayoutKey) private var stackedRowLayoutEnabled: Bool = AppearanceDefaults.stackedRowLayoutDefault

    public init(session: Session, hostApp: HostAppInfo, isUnread: Bool = false, isBridged: Bool = false, showCloudAffordances: Bool = false, showAgentBadge: Bool = true, awaySummary: String? = nil, onDetail: (() -> Void)? = nil) {
        self.session = session
        self.hostApp = hostApp
        self.isUnread = isUnread
        self.isBridged = isBridged
        self.showCloudAffordances = showCloudAffordances
        self.showAgentBadge = showAgentBadge
        self.awaySummary = awaySummary
        self.onDetail = onDetail
    }

    public var body: some View {
        ResultRowLayout(
            status: { AnimatedStatusDot(kind: session.status.statusKind) },
            ageDisplay: ageDisplay,
            content: { mainContent },
            hostApp: hostApp,
            // Accent bar doubles as the unread marker. When per-repo
            // coloring is on, paint the bar with the repo's accent. When
            // it's off, fall back to a neutral unread orange so unread rows
            // still get their strongest left-edge cue. Read rows reserve
            // the 2pt slot but render `Color.clear` so column alignment
            // holds.
            accentColor: unreadAccentColor,
            onDetail: onDetail,
            hostAppBadge: showAgentBadge ? AgentBadgeSpec.forAgent(session.tool) : nil,
            iconAccessibilityLabel: Session.accessibilityLabel(hostApp: hostApp, agent: session.tool),
            isUnread: isUnread
        )
    }

    /// Accent-bar color for the unread marker. `nil` means render the slot
    /// as `Color.clear` (read row). When per-repo coloring is enabled, use
    /// the repo's hashed accent; otherwise fall back to neutral orange so
    /// unread rows aren't silently uncolored when the toggle is off.
    private var unreadAccentColor: Color? {
        guard isUnread else { return nil }
        if repoAccentBarEnabled, let repoColor = repoAccentColor(for: session.gitRepoName) {
            return repoColor
        }
        return .orange
    }

    /// Branches between the new stacked layout and the legacy two-column
    /// layout based on `AppearanceDefaults.stackedRowLayoutKey`. The
    /// stacked path is the new default; the legacy path is kept for A/B
    /// comparison and should be removed once the new design is finalized.
    @ViewBuilder
    private var mainContent: some View {
        if stackedRowLayoutEnabled {
            stackedContent
        } else {
            legacyContent
        }
    }

    /// Single-column stacked row content: sender (line 1), branch / row-kind
    /// glyphs (line 2), and the chat preview (line 3+) all flow vertically
    /// in one column that spans the full content width. The preview wraps
    /// under the sender, getting the full row width instead of competing
    /// with a fixed 180pt sender column.
    ///
    /// **Read-state treatment:** sender stays bold at full opacity in both
    /// states; the preview block dims on read so the row recedes visually
    /// without losing top-line legibility. Row chrome (status dot, time,
    /// accent bar, icon, pill, chevron) stays at full opacity throughout.
    @ViewBuilder
    private var stackedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SenderText(display: session.senderDisplay, isUnread: isUnread, isStacked: true)
                    .foregroundStyle(senderColor())
                if isUnread {
                    UnreadPill()
                }
            }
            .fontWeight(.bold)

            subtitleRow(stacked: true)
                .fontWeight(isUnread ? .bold : .regular)

            previewView
                .padding(.top, 6)
                .opacity(isUnread ? 1.0 : 0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Legacy two-column row content: the left column stacks the sender
    /// (line 1) above the branch / row-kind glyphs (line 2) at a fixed
    /// 180pt width; the right column hosts the chat preview, vertically
    /// centered to span the full row height in the Gmail "subject +
    /// preview reads as prominent as the sender" idiom.
    @ViewBuilder
    private var legacyContent: some View {
        // Top-aligned so the sender column (line 1 + branch line 2) sits
        // flush with the first line of the preview when the row grows to
        // multiple wrapped lines, instead of floating to the vertical
        // center of a tall preview block.
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SenderText(display: session.senderDisplay, isUnread: isUnread, isStacked: false)
                        .foregroundStyle(senderColor())
                    if isUnread {
                        UnreadPill()
                    }
                }

                subtitleRow(stacked: false)
            }
            .fontWeight(isUnread ? .bold : .regular)
            .frame(width: SenderColumnLayout.width, alignment: .leading)

            previewView
                .opacity(isUnread ? 1.0 : 0.6)
        }
    }

    /// Line-2 row-kind-glyphs + branch (or directory-path fallback when
    /// there's no git context). `stacked` selects the font size — legacy
    /// mode matches the sender at 13/14pt, stacked mode demotes to 11/12pt.
    @ViewBuilder
    private func subtitleRow(stacked: Bool) -> some View {
        HStack(spacing: 4) {
            if showCloudAffordances {
                Image(systemName: "laptopcomputer")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .help(isBridged
                          ? "Running locally and on claude.ai (Enter focuses the local terminal)"
                          : "Running locally")
                if isBridged {
                    Image(systemName: "cloud.fill")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .help("Also running on claude.ai")
                }
            }

            if let branch = session.gitBranch, !branch.isEmpty {
                Text(branch)
                    .font(.system(size: SenderColumnLayout.subtitleSize(isUnread: isUnread, stacked: stacked), design: .monospaced))
                    .foregroundStyle(branchColor())
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                // Sessions started outside a git repo fall back to the
                // directory path with middle truncation, mirroring the
                // pre-redesign behavior.
                Text(directoryPath)
                    .font(.system(size: SenderColumnLayout.subtitleSize(isUnread: isUnread, stacked: stacked), design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// Maps `Session.previewContent` to the right typography for the chat
    /// preview column. Per the Gmail idiom, the preview is bumped to
    /// `.title3` (15pt) so it sits as the row's most prominent text, and
    /// goes bold on unread / regular on read — pairing with the read-state
    /// opacity dim to make unread rows feel "fresh" against read rows.
    /// `.userPrompt` / `.statusHint` retain italic + dimmer color to
    /// remain visibly distinct from real assistant output (R3).
    ///
    /// Plain preview column — the unread pill moved up next to the sender
    /// (line 1) so wrapped preview lines flow flush against the column edge
    /// rather than being indented to the right of the pill.
    @ViewBuilder
    private var previewView: some View {
        previewText
            .lineLimit(4)
            .truncationMode(.tail)
            // Eyeballed — small enough to keep 4-line previews compact, large enough
            // that wrapped lines don't read as a single visual block.
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var previewText: some View {
        switch session.previewContent(awaySummary: awaySummary) {
        case .reply(let text):
            Text(text)
                .font(.title3)
                .fontWeight(isUnread ? .semibold : .regular)
                .foregroundStyle(.primary)
        case .userPrompt(let text):
            Text("You: " + text)
                .font(.title3)
                .fontWeight(isUnread ? .semibold : .regular)
                .italic()
                .foregroundStyle(.secondary)
        case .statusHint(let text):
            Text(text)
                .font(.title3)
                .italic()
                .foregroundStyle(.tertiary)
        case .awaySummary(let text):
            // Same typography as `.reply` — the recap is real authored content,
            // not a UI fallback hint. See `PreviewContent.awaySummary` docstring.
            // Inline clock glyph mirrors `AwaySummaryTurnView` in the detail
            // view so the row preview and the transcript card read as the
            // same kind of authored event. Text concatenation lets the glyph
            // flow with the wrapped run instead of pinning the icon outside
            // the text column.
            (
                Text(Image(systemName: "clock")).foregroundColor(.secondary)
                + Text(" ")
                + Text(text)
            )
                .font(.title3)
                .fontWeight(isUnread ? .semibold : .regular)
                .foregroundStyle(.primary)
        }
    }

    /// Branch label color. When per-repo color coding is on, tints with the
    /// repo accent so worktree rows cluster visually with their repo;
    /// otherwise demotes to `.secondary` per R6.
    private func branchColor() -> Color {
        if repoAccentBarEnabled, let color = repoAccentColor(for: session.gitRepoName) {
            return color
        }
        return .secondary
    }

    /// Sender (repo name) color. Mirrors `branchColor()` — when per-repo
    /// color coding is on, the sender picks up the repo accent so the
    /// whole row reads as that repo's color group; otherwise falls back to
    /// `.primary` so the sender keeps its full-strength row-heading
    /// treatment.
    private func senderColor() -> Color {
        if repoAccentBarEnabled, let color = repoAccentColor(for: session.gitRepoName) {
            return color
        }
        return .primary
    }

    /// Full directory path with ~ shortening.
    private var directoryPath: String {
        let dir = session.directory
        let home = NSHomeDirectory()
        if dir.hasPrefix(home) {
            return "~" + dir.dropFirst(home.count)
        }
        return dir
    }

    private var ageDisplay: SessionAgeDisplay {
        SessionAgeDisplay(timestamp: session.updatedAt)
    }
}
