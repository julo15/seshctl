import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

@Suite("SessionDetailViewModel")
@MainActor
struct SessionDetailViewModelTests {

    @Test("Unsupported tool with no transcript sets error")
    func unsupportedToolError() {
        let session = makeSession(tool: .gemini)
        let vm = SessionDetailViewModel(session: session)
        vm.load()
        #expect(vm.error == "No transcript available")
        #expect(!vm.isLoading)
    }

    @Test("Missing conversationId sets error")
    func missingConversationId() {
        let session = makeSession(conversationId: nil)
        let vm = SessionDetailViewModel(session: session)
        vm.load()
        #expect(vm.error == "No transcript available")
        #expect(!vm.isLoading)
    }

    @Test("Missing transcript file sets error")
    func missingFile() {
        let session = makeSession(conversationId: "nonexistent-\(UUID().uuidString)")
        let vm = SessionDetailViewModel(session: session)
        vm.load()
        #expect(vm.error == "No transcript available")
        #expect(!vm.isLoading)
    }

    @Test("Scroll command can be set and cleared")
    func scrollCommand() {
        let vm = SessionDetailViewModel(session: makeSession())
        #expect(vm.scrollCommand == nil)
        vm.scrollCommand = .bottom
        #expect(vm.scrollCommand == .bottom)
        vm.scrollCommand = nil
        #expect(vm.scrollCommand == nil)
    }

    @Test("All scroll command cases are distinct")
    func scrollCommandCases() {
        let all: [SessionDetailViewModel.ScrollCommand] = [
            .lineDown, .lineUp, .halfPageDown, .halfPageUp,
            .pageDown, .pageUp, .top, .bottom
        ]
        // Verify each is unique
        for i in 0..<all.count {
            for j in 0..<all.count {
                if i == j {
                    #expect(all[i] == all[j])
                } else {
                    #expect(all[i] != all[j])
                }
            }
        }
    }

    @Test("gitRepoName forwards the session's gitRepoName")
    func gitRepoNameForwardsSession() {
        let session = makeSession(gitRepoName: "seshctl")
        let vm = SessionDetailViewModel(session: session)
        #expect(vm.gitRepoName == "seshctl")
    }

    @Test("RecallResult init with no session sets displayName from project")
    func recallResultNoSession() {
        let result = makeRecallResult(project: "/Users/julian/Documents/me/seshctl")
        let vm = SessionDetailViewModel(recallResult: result, session: nil)
        #expect(vm.displayName == "seshctl")
        #expect(vm.toolName == "claude")
        #expect(vm.gitBranch == nil)
        #expect(vm.directoryLabel == nil)
        #expect(vm.session == nil)
        #expect(vm.recallResult != nil)
    }

    @Test("RecallResult init with matching session uses session data")
    func recallResultWithSession() {
        let result = makeRecallResult()
        let session = makeSession(tool: .claude, conversationId: "conv-123")
        let vm = SessionDetailViewModel(recallResult: result, session: session)
        #expect(vm.session != nil)
        #expect(vm.displayName == (session.gitRepoName ?? "tmp"))
        #expect(vm.toolName == "claude")
    }

    @Test("RecallResult with deleted transcript explains why and keeps the matched message")
    func recallResultMissingTranscript() {
        let result = makeRecallResult(sessionId: "nonexistent-\(UUID().uuidString)")
        let vm = SessionDetailViewModel(recallResult: result, session: nil)
        vm.load()
        #expect(vm.error == SessionDetailViewModel.deletedTranscriptMessage)
        #expect(vm.indexedMessage == "test recall text")
        #expect(!vm.isLoading)
    }

    @Test("RecallResult resolves its transcript under the injected projects root")
    func recallResultResolvesUnderProjectsRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seshctl-detail-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-somewhere-else")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: projectDir.appendingPathComponent("conv-found.jsonl"))

        let result = makeRecallResult(sessionId: "conv-found")
        let vm = SessionDetailViewModel(recallResult: result, session: nil, projectsRoot: root)
        vm.load()
        #expect(vm.error == nil)
        #expect(vm.indexedMessage == nil)
    }

    // MARK: - Search Tests

    @Test("enterSearch sets searching state")
    func enterSearch() {
        let vm = SessionDetailViewModel(session: makeSession())
        vm.enterSearch()
        #expect(vm.isSearching)
        #expect(vm.searchQuery == "")
        #expect(vm.searchMatches.isEmpty)
        #expect(vm.currentMatchIndex == -1)
    }

    @Test("exitSearch clears all search state")
    func exitSearch() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("h")
        vm.appendSearchCharacter("e")
        vm.exitSearch()
        #expect(!vm.isSearching)
        #expect(vm.searchQuery == "")
        #expect(vm.searchMatches.isEmpty)
        #expect(vm.currentMatchIndex == -1)
    }

    @Test("Search finds matches across turns")
    func searchFindsMatches() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("h")
        vm.appendSearchCharacter("e")
        vm.appendSearchCharacter("l")
        vm.appendSearchCharacter("l")
        vm.appendSearchCharacter("o")
        // "hello" appears in the user message
        #expect(!vm.searchMatches.isEmpty)
        #expect(vm.currentMatchIndex == 0)
    }

    @Test("Search is case insensitive")
    func searchCaseInsensitive() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("H")
        vm.appendSearchCharacter("E")
        vm.appendSearchCharacter("L")
        vm.appendSearchCharacter("L")
        vm.appendSearchCharacter("O")
        #expect(!vm.searchMatches.isEmpty)
    }

    @Test("Search with no results sets empty matches")
    func searchNoResults() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("z")
        vm.appendSearchCharacter("z")
        vm.appendSearchCharacter("z")
        #expect(vm.searchMatches.isEmpty)
        #expect(vm.currentMatchIndex == -1)
    }

    @Test("nextMatch wraps around")
    func nextMatchWraps() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        // Search for "e" which should have multiple matches
        vm.appendSearchCharacter("e")
        let count = vm.searchMatches.count
        #expect(count > 0)
        #expect(vm.currentMatchIndex == 0)

        // Advance to end and wrap
        for _ in 0..<count {
            vm.nextMatch()
        }
        #expect(vm.currentMatchIndex == 0)
    }

    @Test("previousMatch wraps around")
    func previousMatchWraps() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("e")
        #expect(vm.currentMatchIndex == 0)

        vm.previousMatch()
        #expect(vm.currentMatchIndex == vm.searchMatches.count - 1)
    }

    @Test("deleteSearchCharacter updates results")
    func deleteSearchCharacter() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("h")
        vm.appendSearchCharacter("e")
        vm.appendSearchCharacter("l")
        vm.appendSearchCharacter("l")
        vm.appendSearchCharacter("o")
        let helloCount = vm.searchMatches.count

        // Delete back to "hell" — might have different match count
        vm.deleteSearchCharacter()
        #expect(vm.searchQuery == "hell")
        #expect(vm.searchMatches.count >= helloCount)
    }

    @Test("Empty search query clears matches")
    func emptyQueryClearsMatches() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("e")
        #expect(!vm.searchMatches.isEmpty)

        vm.deleteSearchCharacter()
        #expect(vm.searchQuery == "")
        #expect(vm.searchMatches.isEmpty)
    }

    @Test("scrollToTurnId is set when match found")
    func scrollToTurnIdSet() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("h")
        vm.appendSearchCharacter("e")
        vm.appendSearchCharacter("l")
        vm.appendSearchCharacter("l")
        vm.appendSearchCharacter("o")
        #expect(vm.scrollToTurnId != nil)
    }

    @Test("currentMatchRange returns range for matching turn")
    func currentMatchRangeForMatchingTurn() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("h")
        vm.appendSearchCharacter("e")
        vm.appendSearchCharacter("l")
        vm.appendSearchCharacter("l")
        vm.appendSearchCharacter("o")

        #expect(!vm.searchMatches.isEmpty)
        let match = vm.searchMatches[vm.currentMatchIndex]
        let range = vm.currentMatchRange(for: match.turnId)
        #expect(range != nil)
        #expect(range == match.range)
    }

    @Test("currentMatchRange returns nil for non-matching turn")
    func currentMatchRangeForOtherTurn() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("h")
        vm.appendSearchCharacter("e")
        vm.appendSearchCharacter("l")
        vm.appendSearchCharacter("l")
        vm.appendSearchCharacter("o")

        // "hello" is in the first turn; check a different turn returns nil
        let otherTurnId = vm.turns[1].id
        #expect(vm.currentMatchRange(for: otherTurnId) == nil)
    }

    @Test("nextMatch with no matches is a no-op")
    func nextMatchNoMatchesNoop() {
        let vm = makeViewModelWithTurns()
        vm.nextMatch()
        #expect(vm.currentMatchIndex == -1)
    }

    @Test("previousMatch with no matches is a no-op")
    func previousMatchNoMatchesNoop() {
        let vm = makeViewModelWithTurns()
        vm.previousMatch()
        #expect(vm.currentMatchIndex == -1)
    }

    // MARK: - deleteSearchWord Tests

    @Test("deleteSearchWord removes last word")
    func deleteSearchWordRemovesLastWord() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("hello world")
        vm.deleteSearchWord()
        #expect(vm.searchQuery == "hello ")
    }

    @Test("deleteSearchWord removes trailing whitespace then word")
    func deleteSearchWordTrailingWhitespace() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("hello   ")
        vm.deleteSearchWord()
        #expect(vm.searchQuery == "")
    }

    @Test("deleteSearchWord on single word clears query")
    func deleteSearchWordSingleWord() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("hello")
        vm.deleteSearchWord()
        #expect(vm.searchQuery == "")
    }

    @Test("deleteSearchWord on empty query is a no-op")
    func deleteSearchWordEmpty() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.deleteSearchWord()
        #expect(vm.searchQuery == "")
    }

    // MARK: - clearSearchQuery Tests

    @Test("clearSearchQuery clears the query")
    func clearSearchQueryClears() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("hello")
        vm.clearSearchQuery()
        #expect(vm.searchQuery == "")
        #expect(vm.searchMatches.isEmpty)
    }

    @Test("clearSearchQuery on empty query is a no-op")
    func clearSearchQueryEmpty() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.clearSearchQuery()
        #expect(vm.searchQuery == "")
    }

    // MARK: - Multi-character append (paste) Tests

    @Test("appendSearchCharacter with multi-character string")
    func appendMultiCharString() {
        let vm = makeViewModelWithTurns()
        vm.enterSearch()
        vm.appendSearchCharacter("hello")
        #expect(vm.searchQuery == "hello")
        #expect(!vm.searchMatches.isEmpty)
    }

    // MARK: - Display items / search-active

    @Test("displayItems rebuild when turns change")
    func displayItemsRebuild() {
        let vm = SessionDetailViewModel(session: makeSession())
        #expect(vm.displayItems.isEmpty)
        let now = Date()
        vm.turns = [
            .userMessage(text: "hi", timestamp: now),
            .assistantMessage(text: "", toolCalls: [ToolCallSummary(toolName: "Read")], timestamp: now.addingTimeInterval(1)),
            .assistantMessage(text: "done", toolCalls: [], timestamp: now.addingTimeInterval(2)),
        ]
        #expect(vm.displayItems.count == 3)
        if case .userTurn = vm.displayItems[0] {} else { Issue.record("expected userTurn") }
        if case .collapsedToolBlock = vm.displayItems[1] {} else { Issue.record("expected collapsedToolBlock") }
        if case .assistantTurn = vm.displayItems[2] {} else { Issue.record("expected assistantTurn") }
    }

    @Test("isSearchActive reflects searchQuery non-empty")
    func isSearchActiveFlag() {
        let vm = SessionDetailViewModel(session: makeSession())
        #expect(!vm.isSearchActive)
        vm.searchQuery = "foo"
        #expect(vm.isSearchActive)
        vm.searchQuery = ""
        #expect(!vm.isSearchActive)
    }

    // MARK: - Helpers

    private func makeViewModelWithTurns() -> SessionDetailViewModel {
        let vm = SessionDetailViewModel(session: makeSession())
        // Manually set turns since we can't load from disk in tests
        vm.turns = [
            .userMessage(text: "hello world", timestamp: Date(timeIntervalSince1970: 1000)),
            .assistantMessage(text: "I can help with that", toolCalls: [], timestamp: Date(timeIntervalSince1970: 1001)),
            .userMessage(text: "tell me more", timestamp: Date(timeIntervalSince1970: 1002)),
        ]
        return vm
    }

    private func makeRecallResult(
        sessionId: String = "conv-123",
        project: String = "/tmp",
        agent: String = "claude"
    ) -> RecallResult {
        RecallResult(
            agent: agent,
            role: "user",
            sessionId: sessionId,
            project: project,
            timestamp: Date().timeIntervalSince1970,
            score: 0.95,
            resumeCmd: "claude --resume \(sessionId)",
            text: "test recall text"
        )
    }

    private func makeSession(
        tool: SessionTool = .claude,
        conversationId: String? = "test-conv-id",
        gitRepoName: String? = nil
    ) -> Session {
        Session(
            id: UUID().uuidString,
            conversationId: conversationId,
            tool: tool,
            directory: "/tmp",
            launchDirectory: nil,
            hostWorkspaceFolder: nil,
            lastAsk: nil,
            lastReply: nil,
            status: .idle,
            pid: 1234,
            hostAppBundleId: nil,
            hostAppName: nil,
            windowId: nil,
            transcriptPath: nil,
            gitRepoName: gitRepoName,
            startedAt: Date(),
            updatedAt: Date()
        )
    }
}
