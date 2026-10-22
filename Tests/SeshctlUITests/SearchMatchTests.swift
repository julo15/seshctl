import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

/// The `/` match rule: every whitespace-separated word must match, but the
/// words may match different fields.
@Suite("Search match")
struct SearchMatchTests {
    private func session(
        repo: String? = "seshctl",
        branch: String? = nil,
        lastAsk: String? = nil,
        directory: String = "/tmp/seshctl"
    ) -> Session {
        Session(
            id: UUID().uuidString,
            conversationId: nil,
            tool: .claude,
            directory: directory,
            launchDirectory: directory,
            hostWorkspaceFolder: nil,
            lastAsk: lastAsk,
            lastReply: nil,
            status: .stale,
            pid: nil,
            hostAppBundleId: nil,
            hostAppName: nil,
            windowId: nil,
            transcriptPath: nil,
            gitRepoName: repo,
            gitBranch: branch,
            launchArgs: nil,
            startedAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000),
            lastReadAt: nil
        )
    }

    @Test("Every word has to match, but they can match different fields")
    func tokensAreAndedAcrossFields() {
        let row = session()
        let title = "Session deduplication verification"

        // The reason for tokenizing: one `contains` over the whole query
        // needs the words adjacent in a single field, so this found nothing.
        #expect(SessionListViewModel.matches(session: row, title: title, query: "sesh dedup"))
        #expect(SessionListViewModel.matches(session: row, title: title, query: "dedup sesh"))
        #expect(!SessionListViewModel.matches(session: row, title: title, query: "sesh missing"))
    }

    @Test("Matching ignores case and extra whitespace")
    func tokensNormalize() {
        let row = session(lastAsk: "Session deduplication verification")

        #expect(SessionListViewModel.matches(session: row, query: "SESH  DEDUP"))
        #expect(SessionListViewModel.matches(session: row, query: "   "))
    }

    @Test("An empty query matches every row")
    func emptyQueryMatchesEverything() {
        #expect(SessionListViewModel.matches(session: session(repo: nil), query: ""))
        #expect(SessionListViewModel.searchTokens("").isEmpty)
    }

    @Test("A single word matches any one field, as before")
    func singleWordStillMatchesAnyField() {
        let row = session(repo: "location", branch: "julo/signup", lastAsk: "promote pending")

        #expect(SessionListViewModel.matches(session: row, query: "signup"))
        #expect(SessionListViewModel.matches(session: row, query: "pending"))
        #expect(SessionListViewModel.matches(session: row, query: "claude"), "tool name is searchable")
        #expect(!SessionListViewModel.matches(session: row, query: "figma"))
    }

    @Test("Cloud rows use the same word rule over title, repo and branches")
    func remoteRowsTokenize() {
        let remote = RemoteClaudeCodeSession(
            id: "r1",
            title: "Review PR 519",
            model: "claude-opus-4-6[1m]",
            repoUrl: "https://github.com/julo15/location",
            branches: ["julo/linear-context"],
            status: "active",
            workerStatus: "idle",
            connectionStatus: "connected",
            lastEventAt: Date(),
            createdAt: Date(),
            unread: false
        )

        #expect(SessionListViewModel.matches(remote: remote, query: "location 519"))
        #expect(SessionListViewModel.matches(remote: remote, query: "linear review"))
        #expect(!SessionListViewModel.matches(remote: remote, query: "location figma"))
    }

    @Test("Typing a multi-word query narrows the list across fields")
    @MainActor
    func viewModelUsesTheWordRule() throws {
        let db = try SeshctlDatabase.temporary()
        let hit = try db.startSession(tool: .claude, directory: "/tmp/seshctl", pid: 1111)
        try db.updateSession(pid: 1111, tool: .claude, ask: "dedupe the rows", status: .idle)
        try db.startSession(tool: .claude, directory: "/tmp/elmozi", pid: 2222)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        vm.enterSearch()
        for character in "sesh dedupe" { vm.appendSearchCharacter(String(character)) }

        #expect(vm.localFilteredSessions.map(\.id) == [hit.id])
    }
}
