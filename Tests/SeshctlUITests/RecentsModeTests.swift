import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

/// Covers the recents view: the mode toggle, the restore marks, and the set of
/// sessions `enter` dispatches. The restore dispatch itself is covered by
/// `RestoreDispatchTests`.
@Suite("Recents mode")
struct RecentsModeTests {

    /// A database holding one live session and `closedCount` closed ones, each
    /// with its own conversation id so none of them collapse into another.
    private func makeDatabase(closedCount: Int) throws -> SeshctlDatabase {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(
            tool: .claude, directory: "/tmp/live", pid: 9999, conversationId: "live-conv")
        for index in 0..<closedCount {
            let pid = 1000 + index
            try db.startSession(
                tool: .claude,
                directory: "/tmp/closed-\(index)",
                pid: pid,
                conversationId: "closed-conv-\(index)"
            )
            try db.endSession(pid: pid, tool: .claude)
        }
        return db
    }

    @MainActor
    private func makeViewModel(_ db: SeshctlDatabase) -> SessionListViewModel {
        let defaults = UserDefaults(suiteName: "recents-tests-\(UUID().uuidString)")!
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        return vm
    }

    // MARK: - Mode

    @Test("Recents mode is off until the user asks for it")
    @MainActor
    func startsOnActives() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 2))

        #expect(!vm.isRecentsMode)
        #expect(vm.orderedRows.count == 1)
    }

    @Test("Recents mode shows closed sessions instead of live ones")
    @MainActor
    func showsClosedSessions() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 3))
        vm.toggleRecentsMode()

        #expect(vm.isRecentsMode)
        #expect(vm.orderedRows.count == 3)
        #expect(vm.orderedRows.allSatisfy { !$0.isActive })
    }

    @Test("Toggling twice returns to the live list")
    @MainActor
    func toggleReturnsToActives() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 2))
        vm.toggleRecentsMode()
        vm.toggleRecentsMode()

        #expect(!vm.isRecentsMode)
        #expect(vm.orderedRows.count == 1)
    }

    @Test("Sessions Seshctl spawned for itself never reach recents")
    @MainActor
    func selfSpawnedRowsAreHidden() throws {
        // `SessionTitler` runs `claude -p` to name a session. Rows written
        // before the write-time guard landed are still on disk, and each one
        // shows the title it generated for some *other* session as its preview.
        let db = try makeDatabase(closedCount: 2)
        try db.startSession(
            tool: .claude,
            directory: "/",
            pid: 4242,
            conversationId: "titler-conv",
            hostAppBundleId: InternalSession.bundleIdentifier,
            hostAppName: "Seshctl"
        )
        try db.endSession(pid: 4242, tool: .claude)

        let vm = makeViewModel(db)
        vm.enterRecentsMode()

        #expect(vm.orderedRows.count == 2)
        #expect(!vm.recentSessions.contains { $0.conversationId == "titler-conv" })
    }

    @Test("A terminal-hosted closed session still reaches recents")
    @MainActor
    func terminalHostedRowsSurvive() throws {
        let db = try makeDatabase(closedCount: 1)
        try db.startSession(
            tool: .claude,
            directory: "/tmp/real",
            pid: 4243,
            conversationId: "real-conv",
            hostAppBundleId: "com.mitchellh.ghostty",
            hostAppName: "Ghostty"
        )
        try db.endSession(pid: 4243, tool: .claude)

        let vm = makeViewModel(db)
        vm.enterRecentsMode()

        #expect(vm.orderedRows.count == 2)
        #expect(vm.recentSessions.contains { $0.conversationId == "real-conv" })
    }

    @Test("Recents mode clears tree mode")
    @MainActor
    func clearsTreeMode() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 2))
        vm.isTreeMode = true
        vm.enterRecentsMode()

        #expect(!vm.isTreeMode)
        #expect(vm.isRecentsMode)
    }

    @Test("Search inside recents stays inside recents")
    @MainActor
    func searchStaysInRecents() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 2))
        vm.enterRecentsMode()
        vm.enterSearch()

        #expect(vm.isRecentsMode)
        #expect(vm.isSearching)
    }

    @Test("Search started from the live list leaves recents off")
    @MainActor
    func searchFromActivesIsGlobal() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 2))
        vm.enterSearch()

        #expect(!vm.isRecentsMode)
        #expect(vm.isSearching)
    }

    @Test("Tree mode leaves recents mode")
    @MainActor
    func treeLeavesRecents() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 2))
        vm.enterRecentsMode()
        vm.toggleViewMode()

        #expect(!vm.isRecentsMode)
    }

    @Test("Hiding the panel leaves recents mode")
    @MainActor
    func panelHideLeavesRecents() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 2))
        vm.enterRecentsMode()
        vm.toggleMarkAll()
        vm.panelDidHide()

        #expect(!vm.isRecentsMode)
        #expect(vm.markedSessionIds.isEmpty)
    }

    @Test("Selection lands on the first row on entry")
    @MainActor
    func selectionResetsOnEntry() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 3))
        vm.enterRecentsMode()

        #expect(vm.selectedIndex == 0)
    }

    @Test("Entering recents with no closed sessions selects nothing")
    @MainActor
    func emptyRecentsSelectsNothing() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 0))
        vm.enterRecentsMode()

        #expect(vm.selectedIndex == -1)
        #expect(vm.emptyState == .noRecents)
    }

    // MARK: - Marks

    @Test("Space marks and unmarks the selected row")
    @MainActor
    func markTogglesSelected() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 3))
        vm.enterRecentsMode()
        let first = try #require(vm.selectedSession)

        vm.toggleMarkForSelected()
        #expect(vm.markedSessionIds == [first.id])

        vm.toggleMarkForSelected()
        #expect(vm.markedSessionIds.isEmpty)
    }

    @Test("Marking does nothing outside recents mode")
    @MainActor
    func markIgnoredOnActives() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 2))
        vm.toggleMarkForSelected()

        #expect(vm.markedSessionIds.isEmpty)
    }

    @Test("Select all marks every restorable row")
    @MainActor
    func selectAllMarksEverything() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 4))
        vm.enterRecentsMode()
        vm.toggleMarkAll()

        #expect(vm.markedSessionIds.count == 4)
    }

    @Test("Select all clears the marks when everything is already marked")
    @MainActor
    func selectAllTogglesOff() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 4))
        vm.enterRecentsMode()
        vm.toggleMarkAll()
        vm.toggleMarkAll()

        #expect(vm.markedSessionIds.isEmpty)
    }

    @Test("Select all completes a partial selection before clearing it")
    @MainActor
    func selectAllCompletesPartialSelection() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 4))
        vm.enterRecentsMode()
        vm.toggleMarkForSelected()
        vm.toggleMarkAll()

        #expect(vm.markedSessionIds.count == 4)
    }

    @Test("A Cursor session is not listed in recents at all")
    @MainActor
    func cursorRowIsNotListed() throws {
        let db = try SeshctlDatabase.temporary()
        // Cursor has no shell resume CLI, so `buildResumeCommand` returns nil.
        try db.startSession(conversationId: "cur-1", tool: .cursor, directory: "/tmp/cur")
        try db.endSession(conversationId: "cur-1", tool: .cursor)
        let vm = makeViewModel(db)
        vm.enterRecentsMode()

        #expect(vm.orderedRows.isEmpty)
        #expect(vm.emptyState == .noRecents)
    }

    @Test("A row with no conversation id is not listed in recents")
    @MainActor
    func rowWithoutConversationIdIsNotListed() throws {
        let db = try SeshctlDatabase.temporary()
        // No conversation id means nothing to hand to `--resume`.
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 111)
        try db.endSession(pid: 111, tool: .claude)
        let vm = makeViewModel(db)
        vm.enterRecentsMode()

        #expect(vm.recentSessions.count == 1)
        #expect(vm.orderedRows.isEmpty)
    }

    @Test("Recents lists only the rows that can be reopened")
    @MainActor
    func recentsListsOnlyRestorableRows() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(
            tool: .claude, directory: "/tmp/a", pid: 111, conversationId: "conv-1")
        try db.endSession(pid: 111, tool: .claude)
        try db.startSession(conversationId: "cur-1", tool: .cursor, directory: "/tmp/cur")
        try db.endSession(conversationId: "cur-1", tool: .cursor)
        try db.startSession(tool: .claude, directory: "/tmp/b", pid: 222)
        try db.endSession(pid: 222, tool: .claude)

        let vm = makeViewModel(db)
        vm.enterRecentsMode()

        // Three closed rows on disk, one of them restorable.
        #expect(vm.recentSessions.count == 3)
        #expect(vm.orderedRows.count == 1)

        vm.toggleMarkAll()
        #expect(vm.markedSessionIds.count == 1)
    }

    @Test("Every listed row accepts a mark")
    @MainActor
    func everyListedRowIsMarkable() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 4))
        vm.enterRecentsMode()

        let listed = vm.orderedRows.compactMap { row -> Session? in
            if case .local(let session) = row { return session }
            return nil
        }
        #expect(listed.count == 4)
        #expect(listed.allSatisfy { vm.isMarkable($0) })
    }

    @Test("Leaving recents mode clears the marks")
    @MainActor
    func exitClearsMarks() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 3))
        vm.enterRecentsMode()
        vm.toggleMarkAll()
        vm.exitRecentsMode()

        #expect(vm.markedSessionIds.isEmpty)
    }

    @Test("A refresh drops marks whose row disappeared")
    @MainActor
    func refreshPrunesStaleMarks() throws {
        let db = try makeDatabase(closedCount: 3)
        let vm = makeViewModel(db)
        vm.enterRecentsMode()
        vm.toggleMarkAll()
        #expect(vm.markedSessionIds.count == 3)

        let doomed = try #require(vm.recentSessions.first)
        try db.deleteSession(id: doomed.id)
        vm.refresh()

        #expect(vm.markedSessionIds.count == 2)
        #expect(!vm.markedSessionIds.contains(doomed.id))
    }

    // MARK: - What enter restores

    @Test("With nothing marked, enter restores the selected row alone")
    @MainActor
    func restoresSelectedWhenUnmarked() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 3))
        vm.enterRecentsMode()
        let selected = try #require(vm.selectedSession)

        #expect(vm.sessionsToRestore.map(\.id) == [selected.id])
    }

    @Test("With rows marked, enter restores the marked set and ignores selection")
    @MainActor
    func restoresMarkedSet() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 3))
        vm.enterRecentsMode()
        vm.toggleMarkForSelected()
        vm.moveSelectionDown()
        vm.toggleMarkForSelected()
        vm.moveSelectionDown()

        #expect(vm.sessionsToRestore.count == 2)
        #expect(Set(vm.sessionsToRestore.map(\.id)) == vm.markedSessionIds)
    }

    @Test("Restores come back in display order")
    @MainActor
    func restoreOrderMatchesDisplay() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 4))
        vm.enterRecentsMode()
        vm.toggleMarkAll()

        let displayed = vm.orderedRows.compactMap { row -> String? in
            if case .local(let session) = row { return session.id }
            return nil
        }
        #expect(vm.sessionsToRestore.map(\.id) == displayed)
    }

    @Test("Nothing is restorable outside recents mode")
    @MainActor
    func noRestoreOnActives() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 3))

        #expect(vm.sessionsToRestore.isEmpty)
    }

    @Test("An unmarkable selected row restores nothing")
    @MainActor
    func unmarkableSelectionRestoresNothing() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(conversationId: "cur-1", tool: .cursor, directory: "/tmp/cur")
        try db.endSession(conversationId: "cur-1", tool: .cursor)
        let vm = makeViewModel(db)
        vm.enterRecentsMode()

        #expect(vm.sessionsToRestore.isEmpty)
    }

    // MARK: - Dedup reaching the view

    @Test("The view shows one row per conversation")
    @MainActor
    func viewDedupesTwins() throws {
        let db = try SeshctlDatabase.temporary()
        // Three closed runs of one conversation, written directly so they
        // survive `collapseInactiveTwins` and exercise the query-side dedup.
        for index in 0..<3 {
            let session = Session(
                id: "twin-\(index)",
                conversationId: "conv-1",
                tool: .claude,
                directory: "/tmp/a",
                launchDirectory: "/tmp/a",
                hostWorkspaceFolder: nil,
                lastAsk: nil,
                lastReply: nil,
                status: .stale,
                pid: nil,
                hostAppBundleId: nil,
                hostAppName: nil,
                windowId: nil,
                transcriptPath: nil,
                gitRepoName: nil,
                gitBranch: nil,
                launchArgs: nil,
                startedAt: Date(timeIntervalSince1970: 1000),
                updatedAt: Date(timeIntervalSince1970: 1000 + Double(index)),
                lastReadAt: nil
            )
            try db.dbPool.write { try session.insert($0) }
        }

        let vm = makeViewModel(db)
        vm.enterRecentsMode()

        #expect(vm.orderedRows.count == 1)
    }

    @Test("Short conversation id is the first 8 characters")
    func shortConversationId() {
        #expect(
            SessionRowView.shortConversationId("73ec2a60-6e58-46d7-a0ba-3ee22580c56d")
                == "73ec2a60")
        #expect(SessionRowView.shortConversationId(nil) == nil)
        #expect(SessionRowView.shortConversationId("") == nil)
        #expect(SessionRowView.shortConversationId("abc") == "abc")
    }

    // MARK: - Tree mode survives a trip through recents

    @Test("Leaving recents puts tree mode back")
    @MainActor
    func treeModeRestoredOnExit() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 2))
        vm.isTreeMode = true

        vm.enterRecentsMode()
        #expect(!vm.isTreeMode)

        vm.exitRecentsMode()
        #expect(vm.isTreeMode)
    }

    @Test("Recents never overwrites the saved tree preference")
    @MainActor
    func treeModePreferenceSurvivesRecents() throws {
        let db = try makeDatabase(closedCount: 2)
        let suite = "recents-tree-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        vm.isTreeMode = true

        vm.enterRecentsMode()

        // The stored value must still say tree. Writing `false` here is what
        // made one press of `c` destroy the preference for good.
        #expect(defaults.bool(forKey: "seshctl.isTreeMode"))

        // A fresh viewmodel reads the same defaults, as a relaunch would.
        let reopened = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        #expect(reopened.isTreeMode)
    }

    @Test("Hiding the panel puts tree mode back")
    @MainActor
    func treeModeRestoredOnPanelHide() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 2))
        vm.isTreeMode = true
        vm.enterRecentsMode()
        vm.panelDidHide()

        #expect(vm.isTreeMode)
    }

    @Test("Searching inside recents keeps tree mode suspended until the exit")
    @MainActor
    func treeModeRestoredAfterRecentsSearch() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 2))
        vm.isTreeMode = true
        vm.enterRecentsMode()
        vm.enterSearch()

        // The query narrows recents, so recents is still open and tree
        // grouping is still parked. Leaving is what puts it back.
        #expect(!vm.isTreeMode)

        vm.exitRecentsMode()
        #expect(vm.isTreeMode)
    }

    @Test("v from recents toggles the real preference, not the parked value")
    @MainActor
    func toggleViewFromRecentsUsesRealPreference() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 2))
        vm.isTreeMode = true
        vm.enterRecentsMode()

        // Restore to tree, then toggle: the user ends up in list mode.
        vm.toggleViewMode()

        #expect(!vm.isRecentsMode)
        #expect(!vm.isTreeMode)
    }

    @Test("Entering recents with tree mode already off changes nothing")
    @MainActor
    func treeModeOffStaysOff() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 2))
        vm.enterRecentsMode()
        vm.exitRecentsMode()

        #expect(!vm.isTreeMode)
    }

    // MARK: - Recents is closed, local, newest first

    @Test("Recents is ordered newest first")
    @MainActor
    func recentsOrderedDescending() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 5))
        vm.enterRecentsMode()

        let stamps = vm.orderedRows.map(\.sortTimestamp)
        #expect(stamps == stamps.sorted(by: >))
    }

    @Test("Recents holds no active rows")
    @MainActor
    func recentsHoldsNoActiveRows() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 3))
        vm.enterRecentsMode()

        #expect(!vm.orderedRows.isEmpty)
        #expect(vm.orderedRows.allSatisfy { !$0.isActive })
    }

    @Test("Recents holds no remote rows")
    @MainActor
    func recentsHoldsNoRemoteRows() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 3))
        vm.enterRecentsMode()

        let remotes = vm.orderedRows.filter { row in
            if case .remote = row { return true }
            return false
        }
        #expect(remotes.isEmpty)
    }

    @Test("A remote-only source filter does not empty recents")
    @MainActor
    func recentsIgnoresSourceFilter() throws {
        let vm = makeViewModel(try makeDatabase(closedCount: 3))
        vm.sourceFilter = .remoteOnly
        vm.enterRecentsMode()

        #expect(vm.orderedRows.count == 3)
    }

    @Test("Entering recents reloads, so a session closed since is listed")
    @MainActor
    func entryReloadsRecents() throws {
        let db = try makeDatabase(closedCount: 1)
        let vm = makeViewModel(db)
        #expect(vm.recentSessions.count == 1)

        // Close another session behind the viewmodel's back, as quitting a
        // terminal does between two polls.
        try db.endSession(pid: 9999, tool: .claude)
        vm.enterRecentsMode()

        #expect(vm.orderedRows.count == 2)
    }
}
