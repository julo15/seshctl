import Foundation

public struct RecallResult: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(sessionId)-\(timestamp)-\(text.prefix(50))" }

    public let agent: String
    public let role: String
    public let sessionId: String
    public let project: String
    public let timestamp: Double
    public let score: Double
    public let resumeCmd: String
    public let text: String
    /// Excerpt around a keyword match, with matched terms wrapped in
    /// `snippetMatchStart` / `snippetMatchEnd`. `nil` for semantic results.
    public let snippet: String?
    /// A name for the session from the history index: Claude's `ai-title`
    /// (or `custom-title`) when indexed, else the session's first typed
    /// message, cut to one line. `nil` when there's neither.
    public let title: String?

    enum CodingKeys: String, CodingKey {
        case agent
        case role
        case sessionId = "session_id"
        case project
        case timestamp
        case score
        case resumeCmd = "resume_cmd"
        case text
        case snippet
        case title
    }

    public init(
        agent: String,
        role: String,
        sessionId: String,
        project: String,
        timestamp: Double,
        score: Double,
        resumeCmd: String,
        text: String,
        snippet: String? = nil,
        title: String? = nil
    ) {
        self.agent = agent
        self.role = role
        self.sessionId = sessionId
        self.project = project
        self.timestamp = timestamp
        self.score = score
        self.resumeCmd = resumeCmd
        self.text = text
        self.snippet = snippet
        self.title = title
    }

    /// Marks the start of a matched term inside `snippet`.
    public static let snippetMatchStart: Character = "\u{1}"
    /// Marks the end of a matched term inside `snippet`.
    public static let snippetMatchEnd: Character = "\u{2}"

    /// Split a marked snippet into runs of plain and matched text, for
    /// rendering. Whitespace runs (including newlines) collapse to one
    /// space, since rows show the snippet on a single line. Adjacent runs
    /// of the same kind merge; empty runs are dropped.
    public static func snippetSegments(_ snippet: String) -> [(text: String, isMatch: Bool)] {
        var segments: [(text: String, isMatch: Bool)] = []
        var current = ""
        var inMatch = false
        var lastWasSpace = false

        func flush() {
            guard !current.isEmpty else { return }
            if let last = segments.last, last.isMatch == inMatch {
                segments[segments.count - 1].text += current
            } else {
                segments.append((current, inMatch))
            }
            current = ""
        }

        for char in snippet {
            switch char {
            case snippetMatchStart:
                flush()
                inMatch = true
            case snippetMatchEnd:
                flush()
                inMatch = false
            case _ where char.isWhitespace:
                if !lastWasSpace { current.append(" ") }
                lastWasSpace = true
                continue
            default:
                current.append(char)
            }
            lastWasSpace = false
        }
        flush()

        if let first = segments.first {
            segments[0].text = String(first.text.drop(while: { $0 == " " }))
        }
        if let last = segments.last {
            segments[segments.count - 1].text = String(last.text.reversed().drop(while: { $0 == " " }).reversed())
        }
        return segments.filter { !$0.text.isEmpty }
    }
}
