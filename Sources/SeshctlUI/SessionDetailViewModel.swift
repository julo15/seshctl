import Foundation
import SwiftUI
import SeshctlCore

@MainActor
public final class SessionDetailViewModel: ObservableObject {
    public let session: Session?
    public let recallResult: RecallResult?

    @Published public internal(set) var turns: [ConversationTurn] = [] {
        didSet { displayItems = TranscriptDisplay.build(turns) }
    }
    @Published public internal(set) var displayItems: [DisplayItem] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var error: String?
    @Published public var scrollCommand: ScrollCommand?
    @Published public var scrollToTurnId: String?
    public var scrollAnchor: UnitPoint = .center
    @Published public var isSearching: Bool = false
    @Published public var searchQuery: String = ""
    @Published public private(set) var searchMatches: [SearchMatch] = []
    @Published public private(set) var currentMatchIndex: Int = -1

    public struct SearchMatch: Equatable {
        public let turnIndex: Int
        public let turnId: String
        public let range: Range<String.Index>
    }

    public enum ScrollCommand: Equatable {
        case lineDown
        case lineUp
        case halfPageDown
        case halfPageUp
        case pageDown
        case pageUp
        case top
        case bottom
    }

    /// Display name for the header (repo name or directory basename).
    public var displayName: String {
        if let session {
            return session.gitRepoName ?? (session.directory as NSString).lastPathComponent
        }
        if let recallResult {
            // Last path component of project (e.g., "/Users/julian/Documents/me/seshctl" -> "seshctl")
            return (recallResult.project as NSString).lastPathComponent
        }
        return "Unknown"
    }

    /// Tool name for the header.
    public var toolName: String {
        if let session { return session.tool.rawValue }
        if let recallResult { return recallResult.agent }
        return ""
    }

    /// Git branch for the header (only available from Session).
    public var gitBranch: String? {
        session?.gitBranch
    }

    /// Git repo name for this session, if any — used by the header to tint
    /// the worktree label with the repo's accent color.
    public var gitRepoName: String? {
        session?.gitRepoName
    }

    /// True when there is an active search query string. The existing
    /// `isSearching` flag is true while the search bar is open; this is true
    /// only when there's actual query text that should drive highlighting.
    public var isSearchActive: Bool { !searchQuery.isEmpty }

    /// Secondary directory label (when repo name differs from dir name).
    public var directoryLabel: String? {
        guard let session, let repoName = session.gitRepoName else { return nil }
        let dirName = (session.directory as NSString).lastPathComponent
        return dirName != repoName ? dirName : nil
    }

    public init(session: Session) {
        self.session = session
        self.recallResult = nil
    }

    public init(recallResult: RecallResult, session: Session?) {
        self.session = session
        self.recallResult = recallResult
    }

    public func load() {
        let url: URL
        let tool: SessionTool

        if let session {
            guard let sessionURL = TranscriptParser.transcriptURL(for: session) else {
                error = "No transcript available"
                return
            }
            url = sessionURL
            tool = session.tool
        } else if let recallResult {
            url = TranscriptParser.transcriptURL(
                conversationId: recallResult.sessionId,
                directory: recallResult.project
            )
            tool = SessionTool(rawValue: recallResult.agent) ?? .claude
        } else {
            error = "No transcript available"
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            error = "No transcript available"
            return
        }

        isLoading = true
        let fileURL = url
        let parseTool = tool
        Task {
            do {
                let parsed = try await Task.detached {
                    let data = try Data(contentsOf: fileURL)
                    let turns = try TranscriptParser.parse(data: data, tool: parseTool)
                    return turns
                }.value
                self.turns = parsed
                self.isLoading = false
            } catch {
                self.error = "Failed to parse transcript: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    public func enterSearch() {
        isSearching = true
        searchQuery = ""
        searchMatches = []
        currentMatchIndex = -1
    }

    public func exitSearch() {
        isSearching = false
        searchQuery = ""
        searchMatches = []
        currentMatchIndex = -1
    }

    public func updateSearch() {
        guard !searchQuery.isEmpty else {
            searchMatches = []
            currentMatchIndex = -1
            return
        }

        var matches: [SearchMatch] = []

        for (index, turn) in turns.enumerated() {
            let text: String
            switch turn {
            case .userMessage(let t, _): text = t
            case .assistantMessage(let t, _, _): text = t
            case .awaySummary(let t, _): text = t
            }

            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: searchQuery, options: .caseInsensitive, range: searchStart..<text.endIndex) {
                matches.append(SearchMatch(turnIndex: index, turnId: turn.id, range: range))
                searchStart = range.upperBound
            }
        }

        searchMatches = matches
        if matches.isEmpty {
            currentMatchIndex = -1
        } else {
            currentMatchIndex = 0
            scrollToCurrentMatch()
        }
    }

    public func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
        scrollToCurrentMatch()
    }

    public func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        scrollToCurrentMatch()
    }

    public func appendSearchCharacter(_ char: String) {
        searchQuery += char
        updateSearch()
    }

    public func deleteSearchCharacter() {
        guard !searchQuery.isEmpty else { return }
        searchQuery.removeLast()
        updateSearch()
    }

    public func deleteSearchWord() {
        guard !searchQuery.isEmpty else { return }
        while searchQuery.last?.isWhitespace == true { searchQuery.removeLast() }
        while let last = searchQuery.last, !last.isWhitespace { searchQuery.removeLast() }
        updateSearch()
    }

    public func clearSearchQuery() {
        searchQuery = ""
        updateSearch()
    }

    /// Returns the range of the current match if it belongs to the given turn.
    public func currentMatchRange(for turnId: String) -> Range<String.Index>? {
        guard currentMatchIndex >= 0, currentMatchIndex < searchMatches.count else { return nil }
        let match = searchMatches[currentMatchIndex]
        guard match.turnId == turnId else { return nil }
        return match.range
    }

    private func scrollToCurrentMatch() {
        guard currentMatchIndex >= 0, currentMatchIndex < searchMatches.count else { return }
        let match = searchMatches[currentMatchIndex]

        // Estimate vertical position of the match within the turn using character offset.
        let text: String
        switch turns[match.turnIndex] {
        case .userMessage(let t, _): text = t
        case .assistantMessage(let t, _, _): text = t
        case .awaySummary(let t, _): text = t
        }
        let charOffset = text.distance(from: text.startIndex, to: match.range.lowerBound)
        let totalChars = text.count
        let fraction = totalChars > 0 ? CGFloat(charOffset) / CGFloat(totalChars) : 0
        scrollAnchor = UnitPoint(x: 0, y: fraction)

        scrollToTurnId = match.turnId
    }
}
