import SwiftUI
import SeshctlCore

public struct RecallResultRowView: View {
    let result: RecallResult
    /// The matching session's status, when that session is active.
    let liveStatus: SessionStatus?
    let hostApp: HostAppInfo?
    var searchQuery: String?
    /// The transcript is gone from disk: the row can't be resumed, so it
    /// says so and renders hollow.
    var isTranscriptDeleted: Bool
    /// Whether this row is the list's keyboard selection: expands the
    /// message onto up to three lines, like the live rows.
    var isSelected: Bool
    /// The matching session's git repo name, when there is one. Picks the
    /// repo accent; falls back to the folder label, which is usually the
    /// same name.
    var repoName: String?
    /// The session's name (see `SessionListViewModel.historyTitle(for:)`).
    /// Nil falls back to the folder as the headline.
    var title: String?
    var onDetail: (() -> Void)?

    @AppStorage(AppearanceDefaults.repoAccentBarKey) private var repoAccentBarEnabled: Bool = AppearanceDefaults.repoAccentBarDefault

    public init(result: RecallResult, liveStatus: SessionStatus? = nil, hostApp: HostAppInfo? = nil, searchQuery: String? = nil, isTranscriptDeleted: Bool = false, isSelected: Bool = false, repoName: String? = nil, title: String? = nil, onDetail: (() -> Void)? = nil) {
        self.result = result
        self.title = title
        self.isSelected = isSelected
        self.repoName = repoName
        self.liveStatus = liveStatus
        self.isTranscriptDeleted = isTranscriptDeleted
        self.hostApp = hostApp
        self.searchQuery = searchQuery
        self.onDetail = onDetail
    }

    public var body: some View {
        ResultRowLayout(
            status: { statusIndicator },
            ageDisplay: ageDisplay,
            content: { mainContent },
            hostApp: hostApp,
            onDetail: onDetail,
            // The folder sits at the far right in its repo color, as on the
            // live rows, unless it's already the headline.
            trailingLabel: headline != folderLabel ? (folderLabel, folderLabelColor) : nil
        )
    }

    private var statusIndicator: some View {
        AnimatedStatusDot(
            kind: StatusKind.forHistoryResult(liveStatus: liveStatus, isTranscriptDeleted: isTranscriptDeleted),
            age: ageDisplay.bucket
        )
    }

    /// Mirrors `SessionRowView`'s compact layout (fonts, spacing, colors) so
    /// History rows read as the same kind of row as the live list: the
    /// session's name as the headline, the folder at the far right.
    ///
    /// Unlike a live row, the message always gets its own line under the
    /// headline: it's the search match, and squeezed beside a long title
    /// the match was usually truncated out of view.
    @ViewBuilder
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                headlineText
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .help(result.project)

                if isTranscriptDeleted {
                    TagPillView(text: "transcript deleted")
                        .help("This transcript was deleted, so it can't be resumed. \(SessionDetailViewModel.claudeRetentionNote) Enter shows what search history kept.")
                }
            }

            messageText(singleLine: !isSelected)
                .lineLimit(isSelected ? 3 : 2)
                .truncationMode(.tail)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    /// The matched message, styled like a live row's preview: 14pt
    /// secondary, user prompts italic with a `You: ` prefix. Keyword results
    /// highlight exactly the terms FTS matched; semantic results fall back to
    /// highlighting the query's words.
    private func messageText(singleLine: Bool) -> some View {
        let isUser = result.role == "user"
        let body: Text
        if let marked = result.snippet {
            var attributed = AttributedString(isUser ? "You: " : "")
            for segment in RecallResult.snippetSegments(marked) {
                var run = AttributedString(segment.text)
                if segment.isMatch {
                    run.backgroundColor = .yellow.opacity(0.25)
                    run.foregroundColor = .primary
                }
                attributed += run
            }
            body = Text(attributed)
        } else {
            let text = singleLine ? firstLine : result.text
            body = Text(isUser ? "You: " : "") + highlightedText(text, query: searchQuery, perWord: true)
        }
        return body
            .italic(isUser)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
    }

    private var folderLabel: String {
        Session.folderLabel(forDirectory: result.project)
    }

    /// The headline, with matched words highlighted when the search hit the
    /// session's title (`RecallResult.titleMatch`) and that's the title shown.
    private var headlineText: Text {
        guard let marked = result.titleMatch,
              RecallResult.snippetSegments(marked).map(\.text).joined() == headline
        else { return Text(headline) }
        var attributed = AttributedString()
        for segment in RecallResult.snippetSegments(marked) {
            var run = AttributedString(segment.text)
            if segment.isMatch {
                run.backgroundColor = .yellow.opacity(0.25)
                run.foregroundColor = .primary
            }
            attributed += run
        }
        return Text(attributed)
    }

    private var headline: String {
        title.flatMap { $0.isEmpty ? nil : $0 } ?? folderLabel
    }

    /// The repo accent when color coding is on, like the live rows' folder
    /// label; otherwise `.secondary`.
    private var folderLabelColor: Color {
        if repoAccentBarEnabled, let color = repoAccentColor(for: repoName ?? folderLabel) {
            return color
        }
        return .secondary
    }

    private var firstLine: String {
        let cleaned = result.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? result.text
        return String(cleaned.prefix(200))
    }

    private var ageDisplay: SessionAgeDisplay {
        SessionAgeDisplay(timestamp: Date(timeIntervalSince1970: result.timestamp))
    }
}
