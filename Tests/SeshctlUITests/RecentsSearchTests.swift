import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

/// Covers `/` inside the recents view: the token match rule that makes a
/// 100-row list narrowable, and the interaction between a query and the
/// restore marks.
///
/// The mode itself and the restore dispatch are covered by `RecentsModeTests`
/// and `RestoreDispatchTests`.
@Suite("Recents search")
struct RecentsSearchTests {

    // MARK: - Fixtures

    /// A closed session with the fields search reads. Written directly rather
    /// than through `startSession`, which has no way to set a repo or a title.
    private func closedSession(
        id: String,
        repo: String?,
        title: String?,
        directory: String,
        branch: String? = nil,
        tool: SessionTool = .claude,
        age: Double
    ) -> Session {
        Session(
            id: id,
            conversationId: "conv-\(id)",
            tool: tool,
            directory: directory,
            launchDirectory: directory,
            hostWorkspaceFolder: nil,
            lastAsk: nil,
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
            // Larger age means older, so the fixture order below is the
            // display order.
            updatedAt: Date(timeIntervalSince1970: 100_000 - age),
            lastReadAt: nil,
            title: title
        )
    }

    /// Four closed rows modelled on the real database: two in one repo, and a
    /// title whose words are split across the repo and the title.
    private func makeDatabase() throws -> SeshctlDatabase {
        let db = try SeshctlDatabase.temporary()
        let rows = [
            closedSession(
                id: "a", repo: "seshctl",
                title: "Session deduplication verification",
                directory: "/tmp/seshctl", age: 0),
            closedSession(
                id: "b", repo: "location",
                title: "Promote pending location on signup",
                directory: "/tmp/location", age: 1),
            closedSession(
                id: "c", repo: "location",
                title: "Review PR 519 with Linear ticket context",
                directory: "/tmp/location-two", age: 2),
            closedSession(
                id: "d", repo: "elmozi",
                title: "Viewing Figma designs via MCP",
                directory: "/tmp/elmozi", age: 3),
        ]
        for row in rows {
            try db.dbPool.write { try row.insert($0) }
        }
        return db
    }

    @MainActor
    private func makeViewModel(_ db: SeshctlDatabase) -> SessionListViewModel {
        let defaults = UserDefaults(suiteName: "recents-search-\(UUID().uuidString)")!
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        return vm
    }

    @MainActor
    private func type(_ query: String, into vm: SessionListViewModel) {
        for character in query {
            vm.appendSearchCharacter(String(character))
        }
    }

    @MainActor
    private func listedIds(_ vm: SessionListViewModel) -> [String] {
        vm.orderedRows.compactMap { row in
            if case .local(let session) = row { return session.id }
            return nil
        }
    }

    // MARK: - The token rule

    @Test("Every word has to match, but they can match different fields")
    func tokensAreAndedAcrossFields() throws {
        let session = closedSession(
            id: "a", repo: "seshctl",
            title: "Session deduplication verification",
            directory: "/tmp/seshctl", age: 0)

        // The reason for tokenizing: one `contains` over the whole query
        // needs the words adjacent in a single field, so this found nothing.
        #expect(SessionListViewModel.matches(session: session, query: "sesh dedup"))
        #expect(SessionListViewModel.matches(session: session, query: "dedup sesh"))
        #expect(!SessionListViewModel.matches(session: session, query: "sesh missing"))
    }

    @Test("Matching ignores case and extra whitespace")
    func tokensNormalize() throws {
        let session = closedSession(
            id: "a", repo: "seshctl", title: "Session deduplication verification",
            directory: "/tmp/seshctl", age: 0)

        #expect(SessionListViewModel.matches(session: session, query: "SESH  DEDUP"))
        #expect(SessionListViewModel.matches(session: session, query: "   "))
    }

    @Test("An empty query matches every row")
    func emptyQueryMatchesEverything() throws {
        let session = closedSession(
            id: "a", repo: nil, title: nil, directory: "/tmp/a", age: 0)

        #expect(SessionListViewModel.matches(session: session, query: ""))
        #expect(SessionListViewModel.searchTokens("").isEmpty)
    }

    @Test("A row with no title or repo is still found by directory and tool")
    func matchesFallbackFields() throws {
        let session = closedSession(
            id: "a", repo: nil, title: nil, directory: "/tmp/orphan", age: 0)

        #expect(SessionListViewModel.matches(session: session, query: "orphan"))
        #expect(SessionListViewModel.matches(session: session, query: "claude orphan"))
    }

    @Test("The branch is searchable")
    func matchesBranch() throws {
        let session = closedSession(
            id: "a", repo: "seshctl", title: nil, directory: "/tmp/a",
            branch: "tom/recents-search", age: 0)

        #expect(SessionListViewModel.matches(session: session, query: "seshctl recents"))
    }

    @Test("Cloud rows use the same token rule")
    func remoteTokensAreAnded() throws {
        let remote = RemoteClaudeCodeSession(
            id: "r1",
            title: "Diversify repo color palette",
            model: "claude-opus-4-6[1m]",
            repoUrl: "https://github.com/julo15/seshctl",
            branches: ["tom/palette"],
            status: "active",
            workerStatus: "idle",
            connectionStatus: "disconnected",
            lastEventAt: Date(timeIntervalSince1970: 5000),
            createdAt: Date(timeIntervalSince1970: 5000),
            unread: false
        )

        #expect(SessionListViewModel.matches(remote: remote, query: "seshctl palette"))
        #expect(!SessionListViewModel.matches(remote: remote, query: "seshctl missing"))
    }

    // MARK: - Narrowing the list

    @Test("A query narrows the recents list in place")
    @MainActor
    func queryNarrowsRecents() throws {
        let vm = makeViewModel(try makeDatabase())
        vm.enterRecentsMode()
        #expect(listedIds(vm) == ["a", "b", "c", "d"])

        vm.enterSearch()
        type("location", into: vm)

        #expect(vm.isRecentsMode)
        #expect(listedIds(vm) == ["b", "c"])
    }

    @Test("Two words narrow further than one")
    @MainActor
    func twoWordsNarrowFurther() throws {
        let vm = makeViewModel(try makeDatabase())
        vm.enterRecentsMode()
        vm.enterSearch()

        type("location", into: vm)
        #expect(listedIds(vm) == ["b", "c"])

        type(" 519", into: vm)
        #expect(listedIds(vm) == ["c"])
    }

    @Test("A word split across repo and title still matches")
    @MainActor
    func crossFieldQueryMatches() throws {
        let vm = makeViewModel(try makeDatabase())
        vm.enterRecentsMode()
        vm.enterSearch()
        type("sesh dedup", into: vm)

        #expect(listedIds(vm) == ["a"])
    }

    @Test("Narrowed rows come back in recency order")
    @MainActor
    func narrowedRowsKeepOrder() throws {
        let vm = makeViewModel(try makeDatabase())
        vm.enterRecentsMode()
        vm.enterSearch()
        type("tmp", into: vm)

        #expect(listedIds(vm) == ["a", "b", "c", "d"])
    }

    @Test("Clearing the query puts every row back")
    @MainActor
    func clearingQueryRestoresList() throws {
        let vm = makeViewModel(try makeDatabase())
        vm.enterRecentsMode()
        vm.enterSearch()
        type("elmozi", into: vm)
        #expect(listedIds(vm) == ["d"])

        vm.clearSearchQuery()
        #expect(listedIds(vm) == ["a", "b", "c", "d"])
    }

    @Test("A query that matches nothing says so")
    @MainActor
    func noMatchHasItsOwnEmptyState() throws {
        let vm = makeViewModel(try makeDatabase())
        vm.enterRecentsMode()
        vm.enterSearch()
        type("nothing-here", into: vm)

        #expect(vm.orderedRows.isEmpty)
        #expect(vm.emptyState == .noRecentsMatch)
    }

    @Test("An empty recents list still reads as empty, not unmatched")
    @MainActor
    func emptyRecentsKeepsItsOwnState() throws {
        // One live session, no closed ones. A database with nothing at all
        // reports `.fullyEmpty`, which wins over every mode.
        let db = try SeshctlDatabase.temporary()
        try db.startSession(
            tool: .claude, directory: "/tmp/live", pid: 9999, conversationId: "live-conv")
        let vm = makeViewModel(db)
        vm.enterRecentsMode()
        vm.enterSearch()

        #expect(vm.emptyState == .noRecents)
    }

    // MARK: - Marks and the query

    @Test("Select all marks only the rows the query left visible")
    @MainActor
    func selectAllRespectsQuery() throws {
        let vm = makeViewModel(try makeDatabase())
        vm.enterRecentsMode()
        vm.enterSearch()
        type("location", into: vm)
        vm.toggleMarkAll()

        #expect(vm.markedSessionIds == ["b", "c"])
    }

    @Test("A mark survives a query that hides its row")
    @MainActor
    func marksSurviveNarrowing() throws {
        let vm = makeViewModel(try makeDatabase())
        vm.enterRecentsMode()
        vm.enterSearch()

        type("location", into: vm)
        vm.toggleMarkAll()

        type(" nothing-here", into: vm)
        #expect(vm.orderedRows.isEmpty)
        #expect(vm.markedSessionIds == ["b", "c"])
    }

    @Test("Marks are restorable even when the query hides every row")
    @MainActor
    func marksSurviveAnEmptyResult() throws {
        let vm = makeViewModel(try makeDatabase())
        vm.enterRecentsMode()
        vm.enterSearch()
        type("location", into: vm)
        vm.toggleMarkAll()
        type(" nothing-here", into: vm)

        // Nothing is selected, so `enter` has to read the marks, not the row.
        #expect(vm.selectedSession == nil)
        #expect(vm.sessionsToRestore.map(\.id) == ["b", "c"])
    }

    @Test("Marks from two different queries restore together")
    @MainActor
    func marksAccumulateAcrossQueries() throws {
        let vm = makeViewModel(try makeDatabase())
        vm.enterRecentsMode()
        vm.enterSearch()

        type("location", into: vm)
        vm.toggleMarkAll()

        vm.clearSearchQuery()
        type("elmozi", into: vm)
        vm.toggleMarkAll()

        // Hidden marks must not be dropped: resolving against the visible
        // rows would return only the elmozi one.
        #expect(vm.markedSessionIds == ["b", "c", "d"])
        #expect(vm.sessionsToRestore.map(\.id) == ["b", "c", "d"])
    }

    @Test("Select all a second time unmarks only the visible rows")
    @MainActor
    func selectAllUnmarksOnlyVisibleRows() throws {
        let vm = makeViewModel(try makeDatabase())
        vm.enterRecentsMode()
        vm.enterSearch()

        type("location", into: vm)
        vm.toggleMarkAll()
        vm.clearSearchQuery()
        type("elmozi", into: vm)
        vm.toggleMarkAll()
        #expect(vm.markedSessionIds == ["b", "c", "d"])

        // Second press with elmozi still showing: only that row loses its mark.
        vm.toggleMarkAll()
        #expect(vm.markedSessionIds == ["b", "c"])
    }

    @Test("Leaving recents drops the query with the marks")
    @MainActor
    func exitClearsQuery() throws {
        let vm = makeViewModel(try makeDatabase())
        vm.enterRecentsMode()
        vm.enterSearch()
        type("location", into: vm)
        vm.exitRecentsMode()

        #expect(!vm.isSearching)
        #expect(vm.searchQuery.isEmpty)
        #expect(vm.markedSessionIds.isEmpty)
    }

    @Test("Tree mode comes back after a search inside recents")
    @MainActor
    func treeModeSurvivesRecentsSearch() throws {
        let vm = makeViewModel(try makeDatabase())
        vm.isTreeMode = true
        vm.enterRecentsMode()
        vm.enterSearch()
        type("location", into: vm)
        vm.exitRecentsMode()

        #expect(vm.isTreeMode)
    }

    // MARK: - Recall stays out

    /// One test rather than two, because the halves check each other. A
    /// "recall never ran" assertion on its own passes just as well when the
    /// harness is broken and recall could never have run. Driving the same
    /// view model and the same provider into the live list proves the guard
    /// is a guard.
    ///
    /// The positive half polls for 10 seconds. These recall tests share a
    /// known flake: the whole `@MainActor` suite contends for one actor, and
    /// a poll budget sized to the 300ms debounce expires during the stall.
    @Test("Recall runs in the live search and not in recents")
    @MainActor
    func recallRunsOnlyOutsideRecents() async throws {
        let vm = makeViewModel(try makeDatabase())
        // A provider that always fails, so a call leaves a visible mark.
        vm.recallSearchProvider = { _, _ in throw RecallError.timeout }

        vm.enterRecentsMode()
        vm.enterSearch()
        type("location", into: vm)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(vm.recallErrorMessage == nil)
        #expect(vm.recallResults.isEmpty)
        #expect(!vm.isRecallSearching)

        vm.exitRecentsMode()
        vm.enterSearch()
        type("location", into: vm)

        let start = Date()
        while vm.recallErrorMessage == nil && Date().timeIntervalSince(start) < 10.0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(vm.recallErrorMessage == "Semantic search timed out")
    }
}
