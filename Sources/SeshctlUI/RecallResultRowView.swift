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
    var onDetail: (() -> Void)?

    public init(result: RecallResult, liveStatus: SessionStatus? = nil, hostApp: HostAppInfo? = nil, searchQuery: String? = nil, isTranscriptDeleted: Bool = false, onDetail: (() -> Void)? = nil) {
        self.result = result
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
            onDetail: onDetail
        )
    }

    private var statusIndicator: some View {
        AnimatedStatusDot(
            kind: StatusKind.forHistoryResult(liveStatus: liveStatus, isTranscriptDeleted: isTranscriptDeleted),
            age: ageDisplay.bucket
        )
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(projectName)
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Keyword relevance isn't a percentage; only semantic
                // results show a score.
                if result.snippet == nil {
                    Text(scoreLabel)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if isTranscriptDeleted {
                    Label("transcript deleted", systemImage: "trash")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help("This transcript was deleted, so it can't be resumed. \(SessionDetailViewModel.claudeRetentionNote) Enter shows what search history kept.")
                }
            }

            HStack(spacing: 4) {
                Text(roleTag)
                    .font(.body.weight(.bold))
                    .foregroundStyle(.primary.opacity(0.8))
                snippetText
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// Keyword results highlight exactly the terms FTS matched; semantic
    /// results fall back to highlighting the query's words.
    private var snippetText: Text {
        guard let marked = result.snippet else {
            return highlightedText(snippet, query: searchQuery, perWord: true)
        }
        var attributed = AttributedString()
        for segment in RecallResult.snippetSegments(marked) {
            var run = AttributedString(segment.text)
            if segment.isMatch {
                run.backgroundColor = .yellow.opacity(0.25)
            }
            attributed += run
        }
        return Text(attributed)
    }

    private var projectName: String {
        (result.project as NSString).lastPathComponent
    }

    private var scoreLabel: String {
        "\(Int(round(result.score * 100)))%"
    }

    private var roleTag: String {
        result.role == "user" ? "[you]" : "[bot]"
    }

    private var snippet: String {
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
