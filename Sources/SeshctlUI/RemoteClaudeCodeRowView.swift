import SwiftUI
import SeshctlCore

/// Row view for a single cloud `RemoteClaudeCodeSession`. Mirrors the local
/// `SessionRowView` shape from Unit 5 of the Gmail-style row layout — same
/// `ResultRowLayout` slots, same line-1 `SenderText` + preview pattern, same
/// trailing-accessory slot — and swaps in remote-specific data sources so
/// local and remote rows sit in the same grid with identical visual grammar.
///
/// - Line 1: `SenderText(senderDisplay)` + preview slot. `senderDisplay` is
///   sourced from `repoUrl` (`Remote` fallback) via the helper in
///   `RemoteClaudeCodeSession+Display.swift`. The preview is always
///   `.reply(title)` — remote sessions have no `lastReply` / `lastAsk`
///   conversation chain, so R3's italic priority chain doesn't apply.
/// - Line 2: `cloud.fill` glyph + `branches[0]`. When `branches` is empty,
///   `branchDisplay` is nil and the entire line collapses to `EmptyView()`
///   (per R11) so the row reads as single-line. Gated on
///   `showCloudAffordances` so users without a claude.ai connection don't
///   see cloud chrome — though in practice remote rows only render when the
///   user has connected, so this defaults to `true`.
/// - Right side: `globe` SF Symbol + Claude corner badge via
///   `BadgedIcon`, with the unified `Globe, Claude` accessibility label
///   from `Session.accessibilityLabel(hostApp:agent:)`. Phase 1 keeps the
///   `claude.ai` text label as a recognition safety net alongside the
///   badge — Phase 2 removes the label.
/// - Status dot: derived via `StatusKind.forRemote(...)`. The shared
///   `AnimatedStatusDot` renders pulse / blink / solid / dim per
///   `StatusKind`'s decisions.
/// - Stale rows dim at the row-opacity tier (per R12a): the body picks up
///   `.opacity(0.6)` when `isStale` so the dimming reads as inactive-row
///   chrome rather than line-1 typography. Italic on line 1 is reserved for
///   R3's `.userPrompt` / `.statusHint` cases — neither of which applies
///   to remote rows.
public struct RemoteClaudeCodeRowView: View {
    public let session: RemoteClaudeCodeSession
    public let isSelected: Bool
    public let isUnread: Bool
    public let isStale: Bool
    /// Whether to render the line-2 `cloud.fill` glyph. Mirrors the gating
    /// used by `SessionRowView` for the laptop/cloud trio: when the user
    /// hasn't connected claude.ai there's no cloud chrome anywhere. Remote
    /// rows only surface when a connection exists, so this defaults to
    /// `true` — but the parameter exists so callers can suppress the glyph
    /// in preview / test contexts and so the gating contract is explicit.
    public let showCloudAffordances: Bool
    /// Whether to render the agent-kind corner badge over the globe glyph.
    /// Suppressed when the visible row list only contains a single agent
    /// kind. Mirrors the same flag on `SessionRowView`; driven by
    /// `SessionListViewModel.hasMultipleAgentTypes`.
    public let showAgentBadge: Bool
    /// Most recent assistant text for this remote session, if known.
    /// Sourced from `ClaudeCodeConnectionStore.remoteAwaySummariesById` at the
    /// row's construction site. Nil means we haven't fetched yet OR the
    /// session has no assistant turn — either way the row falls through to
    /// `.reply(title)`. See `RemoteClaudeCodeSession.previewContent(awaySummary:)`.
    public let awaySummary: String?
    /// How yesterday-bucket timestamps render in the row's age slot — see
    /// `SessionAgeDisplay.YesterdayStyle`. Driven by the parent view: the
    /// time-sorted inbox passes `.timeOfDay`, the repo-grouped tree view
    /// passes `.relativeDay`.
    public let yesterdayStyle: SessionAgeDisplay.YesterdayStyle

    @AppStorage(AppearanceDefaults.repoAccentBarKey) private var repoAccentBarEnabled: Bool = AppearanceDefaults.repoAccentBarDefault
    @AppStorage(AppearanceDefaults.stackedRowLayoutKey) private var stackedRowLayoutEnabled: Bool = AppearanceDefaults.stackedRowLayoutDefault

    public init(
        session: RemoteClaudeCodeSession,
        isSelected: Bool = false,
        isUnread: Bool = false,
        isStale: Bool = false,
        showCloudAffordances: Bool = true,
        showAgentBadge: Bool = true,
        awaySummary: String? = nil,
        yesterdayStyle: SessionAgeDisplay.YesterdayStyle = .date
    ) {
        self.session = session
        self.isSelected = isSelected
        self.isUnread = isUnread
        self.isStale = isStale
        self.showCloudAffordances = showCloudAffordances
        self.showAgentBadge = showAgentBadge
        self.awaySummary = awaySummary
        self.yesterdayStyle = yesterdayStyle
    }

    public var body: some View {
        ResultRowLayout(
            status: { AnimatedStatusDot(kind: statusKind) },
            ageDisplay: SessionAgeDisplay(timestamp: session.lastEventAt, yesterdayStyle: yesterdayStyle),
            content: { mainContent },
            hostApp: nil,
            // Remote sessions live on claude.ai, not in a macOS app — use a
            // neutral globe glyph so we don't imply a specific browser.
            hostAppSystemSymbol: "globe",
            // Accent bar doubles as the unread marker. When per-repo
            // coloring is on, paint the bar with the repo's hashed accent;
            // when it's off, fall back to neutral orange so unread rows
            // still get their strongest left-edge cue. Stale rows always
            // suppress the bar — staleness implies the row's chrome should
            // recede regardless of unread state.
            accentColor: unreadAccentColor,
            onDetail: nil,
            hostAppBadge: showAgentBadge ? AgentBadgeSpec.forRemote(model: session.model) : nil,
            iconAccessibilityLabel: Session.accessibilityLabel(hostApp: nil, agent: .claude),
            isUnread: isUnread
        )
        // Stale-row dimming lives at the row-opacity tier (R12a). Line-1
        // italic is reserved for R3's userPrompt/statusHint cases — which
        // remote rows never hit — so the body styling stays regular and
        // staleness reads through opacity instead.
        .opacity(isStale ? 0.6 : 1.0)
    }

    /// Repo short name extracted from `session.repoUrl`. Used as the
    /// hash key for the accent color. Returns `""` when no short name can
    /// be derived — the accent-color path falls through to its "no accent"
    /// branch.
    private var repo: String {
        DisplayRow.repoShortName(from: session.repoUrl) ?? ""
    }

    /// Accent-bar color for the unread marker. Mirrors the local-row helper
    /// in `SessionRowView`, with the additional remote-only guard that
    /// stale rows never paint the bar (staleness already dims the row;
    /// adding an accent bar reads as conflicting signal).
    private var unreadAccentColor: Color? {
        guard isUnread && !isStale else { return nil }
        if repoAccentBarEnabled, let repoColor = repoAccentColor(for: repo) {
            return repoColor
        }
        return .orange
    }

    private var statusKind: StatusKind {
        StatusKind.forRemote(
            workerStatus: session.workerStatus,
            connectionStatus: session.connectionStatus,
            isStale: isStale
        )
    }

    /// Branches between stacked and legacy row layouts. Mirrors the same
    /// toggle on `SessionRowView` so local and remote rows stay visually
    /// consistent under both modes.
    @ViewBuilder
    private var mainContent: some View {
        if stackedRowLayoutEnabled {
            stackedContent
        } else {
            legacyContent
        }
    }

    /// Single-column stacked row content mirroring
    /// `SessionRowView.stackedContent`: sender (line 1), cloud + branch
    /// subtitle (line 2), and the chat preview (line 3+) all flow vertically
    /// in one column that spans the full content width.
    @ViewBuilder
    private var stackedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SenderText(display: session.senderDisplay, isUnread: isUnread, isStacked: true)
                    .foregroundStyle(senderColor(for: repo))
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

    /// Legacy two-column content mirroring
    /// `SessionRowView.legacyContent`. Sender + branch sit at a fixed
    /// 180pt column on the left; preview occupies the remaining width.
    @ViewBuilder
    private var legacyContent: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SenderText(display: session.senderDisplay, isUnread: isUnread, isStacked: false)
                        .foregroundStyle(senderColor(for: repo))
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

    /// Chat-preview column. Remote sessions resolve to either `.awaySummary`
    /// (when the connection store has a cached claude.ai recap for this
    /// session — see `previewContent(awaySummary:)` on
    /// `RemoteClaudeCodeSession`) or `.reply(title)` as the fallback. The
    /// `.userPrompt` and `.statusHint` cases are handled here for
    /// exhaustiveness only — remote sessions have no `lastReply` /
    /// `lastAsk` priority chain that would surface them — keeping the
    /// typography mapping consistent with `SessionRowView.previewView`
    /// (15pt title3, bold-on-unread).
    ///
    /// Plain preview column — the unread pill moved up next to the sender
    /// (line 1), mirroring `SessionRowView.previewView`, so wrapped preview
    /// lines flow flush against the column edge.
    @ViewBuilder
    private var previewView: some View {
        previewText
            .lineLimit(4)
            .truncationMode(.tail)
            // Mirrors SessionRowView's eyeballed preview line spacing.
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var previewText: some View {
        switch session.previewContent(awaySummary: awaySummary) {
        case .reply(let text):
            Text(text)
                .font(.title3)
                .fontWeight(isUnread ? previewUnreadWeight : .regular)
                .foregroundStyle(.primary)
        case .userPrompt(let text):
            Text("You: " + text)
                .font(.title3)
                .fontWeight(isUnread ? previewUnreadWeight : .regular)
                .italic()
                .foregroundStyle(.secondary)
        case .statusHint(let text):
            Text(text)
                .font(.title3)
                .italic()
                .foregroundStyle(.tertiary)
        case .awaySummary(let text):
            // The claude.ai assistant-text recap fetched via
            // `ClaudeCodeConnectionStore.remoteAwaySummariesById` (per-session
            // cache populated by per-session `/events` calls). Rendered with
            // a leading clock glyph and the same `.title3` / bold-on-unread
            // typography as local rows so remote recaps read identically.
            (
                Text(Image(systemName: "clock")).foregroundColor(.secondary)
                + Text(" ")
                + Text(text)
            )
                .font(.title3)
                .fontWeight(isUnread ? previewUnreadWeight : .regular)
                .foregroundStyle(.primary)
        }
    }

    /// Unread preview font weight. Legacy mode uses `.bold` to preserve
    /// the pre-stacked-layout shipped behavior; stacked mode picks
    /// `.semibold` so the preview doesn't compete with the always-bold
    /// sender heading. Mirrors `SessionRowView.previewUnreadWeight`.
    private var previewUnreadWeight: Font.Weight {
        stackedRowLayoutEnabled ? .semibold : .bold
    }

    /// Line 2: `cloud.fill` prefix glyph + branch. Constrained to the
    /// sender column's fixed width via the parent VStack `.frame`, so long
    /// branches ellipsize cleanly. Renders nothing when `branchDisplay`
    /// is nil so the row reads as single-line (R11). `stacked` selects
    /// the font size — legacy mode matches the sender at 13/14pt, stacked
    /// demotes to 11/12pt.
    @ViewBuilder
    private func subtitleRow(stacked: Bool) -> some View {
        if let branch = session.branchDisplay, !branch.isEmpty {
            HStack(spacing: 4) {
                if showCloudAffordances {
                    Image(systemName: "cloud.fill")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .help("Runs on claude.ai only")
                }
                Text(branch)
                    .font(.system(size: SenderColumnLayout.subtitleSize(isUnread: isUnread, stacked: stacked), design: .monospaced))
                    .foregroundStyle(branchColor(for: repo))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            EmptyView()
        }
    }

    /// Branch label color. Remote rows have no dir-label slot so the
    /// branch always picks up the repo accent when coloring is on; when
    /// off, the historic `.secondary` treatment.
    private func branchColor(for repoName: String?) -> Color {
        if repoAccentBarEnabled, let color = repoAccentColor(for: repoName) {
            return color
        }
        return .secondary
    }

    /// Sender (repo name) color. Mirrors `branchColor(for:)` but falls
    /// back to `.primary` instead of `.secondary` so the sender keeps its
    /// row-heading treatment when per-repo coloring is off.
    private func senderColor(for repoName: String?) -> Color {
        if repoAccentBarEnabled, let color = repoAccentColor(for: repoName) {
            return color
        }
        return .primary
    }
}
