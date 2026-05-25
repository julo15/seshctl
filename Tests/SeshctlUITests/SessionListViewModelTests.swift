import Foundation
import Testing

import GRDB

@testable import SeshctlCore
@testable import SeshctlUI


@Suite("SessionListViewModel")
struct SessionListViewModelTests {
    @Test("Refresh loads sessions from database")
    @MainActor
    func refreshLoadsSessions() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/project-a", pid: 1111)
        try db.startSession(tool: .gemini, directory: "/tmp/project-b", pid: 2222)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.sessions.count == 2)
        #expect(vm.error == nil)
    }

    @Test("Active sessions filters correctly")
    @MainActor
    func activeSessions() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1111)
        try db.startSession(tool: .gemini, directory: "/tmp/b", pid: 2222)
        try db.endSession(pid: 2222, tool: .gemini)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.localActiveSessions.count == 1)
        #expect(vm.localActiveSessions[0].tool == .claude)
    }

    @Test("Recent sessions filters correctly")
    @MainActor
    func recentSessions() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1111)
        try db.startSession(tool: .gemini, directory: "/tmp/b", pid: 2222)
        try db.endSession(pid: 2222, tool: .gemini)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.localRecentSessions.count == 1)
        #expect(vm.localRecentSessions[0].tool == .gemini)
    }

    @Test("Empty database shows no sessions")
    @MainActor
    func emptySessions() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.sessions.isEmpty)
        #expect(vm.localActiveSessions.isEmpty)
        #expect(vm.localRecentSessions.isEmpty)
        #expect(vm.error == nil)
    }

    @Test("Refresh updates after database changes")
    @MainActor
    func refreshUpdates() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)

        vm.refresh()
        #expect(vm.sessions.isEmpty)

        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        vm.refresh()
        #expect(vm.sessions.count == 1)

        try db.updateSession(pid: 1234, tool: .claude, ask: "hello", status: .working)
        vm.refresh()
        #expect(vm.sessions[0].status == .working)
        #expect(vm.sessions[0].lastAsk == "hello")
    }

    @Test("Working sessions appear in active list")
    @MainActor
    func workingIsActive() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        try db.updateSession(pid: 1234, tool: .claude, status: .working)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.localActiveSessions.count == 1)
        #expect(vm.localActiveSessions[0].status == .working)
    }

    @Test("Stale sessions appear in recent list")
    @MainActor
    func staleIsRecent() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 99999)
        _ = try db.gc(isProcessAlive: { _ in false })

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.localActiveSessions.isEmpty)
        #expect(vm.localRecentSessions.count == 1)
        #expect(vm.localRecentSessions[0].status == .stale)
    }

    // MARK: - Selection Tests

    @Test("Selection starts at 0")
    @MainActor
    func selectionStartsAtZero() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        #expect(vm.selectedIndex == 0)
    }

    @Test("Move selection down")
    @MainActor
    func moveDown() throws {
        let db = try SeshctlDatabase.temporary()
        for i in 1...3 { try db.startSession(tool: .claude, directory: "/tmp/\(i)", pid: i) }

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.moveSelectionDown()
        #expect(vm.selectedIndex == 1)
        vm.moveSelectionDown()
        #expect(vm.selectedIndex == 2)
    }

    @Test("Move selection down clamps at end")
    @MainActor
    func moveDownClamps() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.moveSelectionDown()
        vm.moveSelectionDown()
        vm.moveSelectionDown()
        #expect(vm.selectedIndex == 0) // only 1 session
    }

    @Test("Move selection up")
    @MainActor
    func moveUp() throws {
        let db = try SeshctlDatabase.temporary()
        for i in 1...3 { try db.startSession(tool: .claude, directory: "/tmp/\(i)", pid: i) }

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.selectedIndex = 2
        vm.moveSelectionUp()
        #expect(vm.selectedIndex == 1)
        vm.moveSelectionUp()
        #expect(vm.selectedIndex == 0)
    }

    @Test("Move selection up clamps at top")
    @MainActor
    func moveUpClamps() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.moveSelectionUp()
        #expect(vm.selectedIndex == 0)
    }

    @Test("Selected session returns correct session")
    @MainActor
    func selectedSession() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)
        try db.startSession(tool: .gemini, directory: "/tmp/b", pid: 2)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        // sessions are ordered by updated_at DESC, so gemini (pid 2) is first
        #expect(vm.selectedSession?.tool == .gemini)

        vm.moveSelectionDown()
        #expect(vm.selectedSession?.tool == .claude)
    }

    @Test("Selected session returns nil for empty list")
    @MainActor
    func selectedSessionEmpty() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.selectedSession == nil)
    }

    @Test("Reset selection goes back to 0")
    @MainActor
    func resetSelection() throws {
        let db = try SeshctlDatabase.temporary()
        for i in 1...3 { try db.startSession(tool: .claude, directory: "/tmp/\(i)", pid: i) }

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.selectedIndex = 2
        vm.resetSelection()
        #expect(vm.selectedIndex == 0)
    }

    // MARK: - Focus Memory Tests

    @Test("Reset selection restores remembered session")
    @MainActor
    func resetSelectionRestoresRemembered() throws {
        let db = try SeshctlDatabase.temporary()
        for i in 1...3 { try db.startSession(tool: .claude, directory: "/tmp/\(i)", pid: i) }

        let vm = SessionListViewModel(database: db, enableGC: false, focusMemoryWindow: 60)
        vm.refresh()

        // Remember the second session (index 1)
        let target = vm.localOrderedSessions[1]
        vm.rememberFocusedSession(target)

        vm.selectedIndex = 0
        vm.resetSelection()
        #expect(vm.selectedIndex == 1)
    }

    @Test("Reset selection falls back to 0 after memory window expires")
    @MainActor
    func resetSelectionExpired() throws {
        let db = try SeshctlDatabase.temporary()
        for i in 1...3 { try db.startSession(tool: .claude, directory: "/tmp/\(i)", pid: i) }

        // Use a tiny window so it expires immediately
        let vm = SessionListViewModel(database: db, enableGC: false, focusMemoryWindow: 0)
        vm.refresh()

        let target = vm.localOrderedSessions[1]
        vm.rememberFocusedSession(target)

        vm.selectedIndex = 2
        vm.resetSelection()
        #expect(vm.selectedIndex == 0)
    }

    @Test("Reset selection falls back to 0 when remembered session is gone")
    @MainActor
    func resetSelectionMissingSession() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)
        try db.startSession(tool: .gemini, directory: "/tmp/b", pid: 2)

        let vm = SessionListViewModel(database: db, enableGC: false, focusMemoryWindow: 60)
        vm.refresh()

        // Remember gemini session, then end it
        let gemini = vm.localOrderedSessions.first { $0.tool == .gemini }!
        vm.rememberFocusedSession(gemini)

        try db.endSession(pid: 2, tool: .gemini)
        vm.refresh()

        // Completed session should not be restored — falls back to 0
        vm.resetSelection()
        #expect(vm.selectedIndex == 0)
    }

    @Test("Focus memory distinguishes sessions in the same directory")
    @MainActor
    func focusMemoryByIdNotDirectory() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/shared", pid: 1)
        try db.startSession(tool: .gemini, directory: "/tmp/shared", pid: 2)

        let vm = SessionListViewModel(database: db, enableGC: false, focusMemoryWindow: 60)
        vm.refresh()

        let ordered = vm.localOrderedSessions
        // Remember the second session specifically
        let second = ordered[1]
        vm.rememberFocusedSession(second)

        vm.selectedIndex = 0
        vm.resetSelection()
        #expect(vm.selectedIndex == 1)
        #expect(vm.selectedSession?.id == second.id)
    }

    // MARK: - Kill Flow Tests

    @Test("requestKill sets pendingKillSessionId for active session")
    @MainActor
    func requestKillSetsIdForActive() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/kill", pid: 5555)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestKill()
        #expect(vm.pendingKillSessionId == session.id)
    }

    @Test("requestKill does nothing for inactive session")
    @MainActor
    func requestKillInactiveNoop() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/kill", pid: 5555)
        try db.endSession(pid: 5555, tool: .claude)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestKill()
        #expect(vm.pendingKillSessionId == nil)
    }

    @Test("requestKill does nothing for session without PID")
    @MainActor
    func requestKillNoPidNoop() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/kill", pid: 5555)

        // Clear the PID directly via GRDB to simulate a session with no PID
        try db.dbPool.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE sessions SET pid = NULL WHERE id = ?",
                arguments: [session.id]
            )
        }

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestKill()
        #expect(vm.pendingKillSessionId == nil)
    }

    @Test("cancelKill clears pendingKillSessionId")
    @MainActor
    func cancelKillClearsId() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/kill", pid: 5555)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestKill()
        #expect(vm.pendingKillSessionId != nil)

        vm.cancelKill()
        #expect(vm.pendingKillSessionId == nil)
    }

    @Test("Selection change clears pendingKillSessionId")
    @MainActor
    func selectionChangeClearsKillId() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1111)
        try db.startSession(tool: .gemini, directory: "/tmp/b", pid: 2222)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestKill()
        #expect(vm.pendingKillSessionId != nil)

        vm.moveSelectionDown()
        #expect(vm.pendingKillSessionId == nil)
    }

    // MARK: - Fork Flow Tests

    @Test("requestFork sets pendingForkSessionId for Claude selection")
    @MainActor
    func requestForkSetsIdForClaude() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/fork", pid: 6666)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestFork()
        #expect(vm.pendingForkSessionId == session.id)
    }

    @Test("requestFork is no-op for Gemini selection")
    @MainActor
    func requestForkGeminiNoop() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .gemini, directory: "/tmp/fork", pid: 6666)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestFork()
        #expect(vm.pendingForkSessionId == nil)
    }

    @Test("requestFork is no-op for Codex selection")
    @MainActor
    func requestForkCodexNoop() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .codex, directory: "/tmp/fork", pid: 6666)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestFork()
        #expect(vm.pendingForkSessionId == nil)
    }

    @Test("requestFork is no-op for remote (cloud) Claude selection")
    @MainActor
    func requestForkRemoteNoop() throws {
        let db = try SeshctlDatabase.temporary()
        let remote = makeRemoteForMarkRead(
            id: "cse_fork_remote",
            lastEventAt: Date(timeIntervalSinceNow: -60),
            unread: false
        )
        try db.upsertRemoteClaudeCodeSessions([remote])

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.selectedRow?.id == "cse_fork_remote")

        vm.requestFork()
        #expect(vm.pendingForkSessionId == nil)
    }

    @Test("confirmFork returns the previously-pending id and clears state")
    @MainActor
    func confirmForkReturnsAndClears() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/fork", pid: 6666)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestFork()
        #expect(vm.pendingForkSessionId == session.id)

        let returned = vm.confirmFork()
        #expect(returned == session.id)
        #expect(vm.pendingForkSessionId == nil)
    }

    @Test("cancelFork clears pendingForkSessionId")
    @MainActor
    func cancelForkClearsId() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/fork", pid: 6666)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestFork()
        #expect(vm.pendingForkSessionId != nil)

        vm.cancelFork()
        #expect(vm.pendingForkSessionId == nil)
    }

    @Test("Selection movement clears pendingForkSessionId")
    @MainActor
    func selectionChangeClearsForkId() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1111)
        try db.startSession(tool: .claude, directory: "/tmp/b", pid: 2222)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestFork()
        #expect(vm.pendingForkSessionId != nil)

        vm.moveSelectionDown()
        #expect(vm.pendingForkSessionId == nil)
    }

    // MARK: - Unread Tests

    @Test("Session with activity after start is unread")
    @MainActor
    func activityAfterStartIsUnread() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        // Simulate activity after start so updatedAt > lastReadAt
        Thread.sleep(forTimeInterval: 0.01)
        try db.updateSession(pid: 1234, tool: .claude, ask: "hello", status: .idle)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.unreadSessionIds.contains(session.id))
    }

    @Test("Never-read session in working state is NOT unread")
    @MainActor
    func neverReadWorkingNotUnread() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        try db.updateSession(pid: 1234, tool: .claude, status: .working)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(!vm.unreadSessionIds.contains(session.id))
    }

    @Test("Working sessions excluded from unread set, waiting sessions included")
    @MainActor
    func workingNotUnreadWaitingIsUnread() throws {
        let db = try SeshctlDatabase.temporary()
        let s1 = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1111)
        Thread.sleep(forTimeInterval: 0.01)
        try db.updateSession(pid: 1111, tool: .claude, status: .working)

        let s2 = try db.startSession(tool: .gemini, directory: "/tmp/b", pid: 2222)
        Thread.sleep(forTimeInterval: 0.01)
        try db.updateSession(pid: 2222, tool: .gemini, status: .working)
        try db.updateSession(pid: 2222, tool: .gemini, status: .waiting)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        // Working is not unread (still in progress)
        #expect(!vm.unreadSessionIds.contains(s1.id))
        // Waiting IS unread (needs user attention)
        #expect(vm.unreadSessionIds.contains(s2.id))
    }

    @Test("Unread set includes sessions with updatedAt > lastReadAt in actionable states")
    @MainActor
    func unreadAfterUpdate() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        // Mark as read
        try db.markSessionRead(id: session.id)

        // Ensure updatedAt > lastReadAt (avoid same-millisecond timestamps)
        Thread.sleep(forTimeInterval: 0.01)

        // Update the session (simulates new activity)
        try db.updateSession(pid: 1234, tool: .claude, ask: "new question", status: .idle)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.unreadSessionIds.contains(session.id))
    }

    @Test("markSessionRead removes session from unread set")
    @MainActor
    func markReadRemovesFromUnread() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        // Simulate activity so session becomes unread
        Thread.sleep(forTimeInterval: 0.01)
        try db.updateSession(pid: 1234, tool: .claude, ask: "hello", status: .idle)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.unreadSessionIds.contains(session.id))

        let updated = try db.findActiveSession(pid: 1234, tool: .claude)!
        vm.markSessionRead(updated)
        #expect(!vm.unreadSessionIds.contains(session.id))
    }

    @Test("Completed session is unread when completed after start")
    @MainActor
    func completedAfterStartIsUnread() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        // Ensure updatedAt > lastReadAt
        Thread.sleep(forTimeInterval: 0.01)
        try db.endSession(pid: 1234, tool: .claude)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.unreadSessionIds.contains(session.id))
    }

    @Test("Read session that completes becomes unread again")
    @MainActor
    func readThenCompletedBecomesUnread() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        // Mark as read while idle
        try db.markSessionRead(id: session.id)

        // Ensure updatedAt > lastReadAt (avoid same-millisecond timestamps)
        Thread.sleep(forTimeInterval: 0.01)

        // Session completes (updates updatedAt)
        try db.endSession(pid: 1234, tool: .claude)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.unreadSessionIds.contains(session.id))
    }

    // MARK: - Mark All Read Tests

    @Test("requestMarkAllRead sets pending flag when unread sessions exist")
    @MainActor
    func requestMarkAllReadSetsPending() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        Thread.sleep(forTimeInterval: 0.01)
        try db.updateSession(pid: 1234, tool: .claude, ask: "hello", status: .idle)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(!vm.unreadSessionIds.isEmpty)

        vm.requestMarkAllRead()
        #expect(vm.pendingMarkAllRead == true)
    }

    @Test("requestMarkAllRead is no-op when no unread sessions")
    @MainActor
    func requestMarkAllReadNoopWhenAllRead() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.unreadSessionIds.isEmpty)

        vm.requestMarkAllRead()
        #expect(vm.pendingMarkAllRead == false)
    }

    @Test("confirmMarkAllRead clears all unread sessions")
    @MainActor
    func confirmMarkAllReadClearsUnread() throws {
        let db = try SeshctlDatabase.temporary()
        let s1 = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1111)
        Thread.sleep(forTimeInterval: 0.01)
        try db.updateSession(pid: 1111, tool: .claude, ask: "hello", status: .idle)

        let s2 = try db.startSession(tool: .gemini, directory: "/tmp/b", pid: 2222)
        Thread.sleep(forTimeInterval: 0.01)
        try db.updateSession(pid: 2222, tool: .gemini, ask: "world", status: .idle)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.unreadSessionIds.contains(s1.id))
        #expect(vm.unreadSessionIds.contains(s2.id))

        vm.requestMarkAllRead()
        vm.confirmMarkAllRead()

        #expect(vm.unreadSessionIds.isEmpty)
        #expect(vm.pendingMarkAllRead == false)
    }

    @Test("cancelMarkAllRead resets pending flag")
    @MainActor
    func cancelMarkAllReadResetsPending() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        Thread.sleep(forTimeInterval: 0.01)
        try db.updateSession(pid: 1234, tool: .claude, ask: "hello", status: .idle)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.unreadSessionIds.contains(session.id))

        vm.requestMarkAllRead()
        #expect(vm.pendingMarkAllRead == true)

        vm.cancelMarkAllRead()
        #expect(vm.pendingMarkAllRead == false)
        #expect(vm.unreadSessionIds.contains(session.id))
    }

    @Test("Selection change clears pendingMarkAllRead")
    @MainActor
    func selectionChangeClearsPendingMarkAllRead() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1111)
        Thread.sleep(forTimeInterval: 0.01)
        try db.updateSession(pid: 1111, tool: .claude, ask: "hello", status: .idle)

        try db.startSession(tool: .gemini, directory: "/tmp/b", pid: 2222)
        Thread.sleep(forTimeInterval: 0.01)
        try db.updateSession(pid: 2222, tool: .gemini, ask: "world", status: .idle)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestMarkAllRead()
        #expect(vm.pendingMarkAllRead == true)

        vm.moveSelectionDown()
        #expect(vm.pendingMarkAllRead == false)
    }

    // MARK: - markSelectedRowRead Tests (local, remote, none branches)

    private func makeRemoteForMarkRead(
        id: String,
        lastEventAt: Date = Date(),
        unread: Bool = true
    ) -> RemoteClaudeCodeSession {
        RemoteClaudeCodeSession(
            id: id,
            title: "Remote session",
            model: "claude-opus-4-7",
            repoUrl: "https://github.com/julo15/example",
            branches: ["main"],
            status: "active",
            workerStatus: "idle",
            connectionStatus: "connected",
            lastEventAt: lastEventAt,
            createdAt: lastEventAt,
            unread: unread
        )
    }

    @Test("markSelectedRowRead on local selection removes id from unreadSessionIds")
    @MainActor
    func markSelectedRowReadLocal() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        Thread.sleep(forTimeInterval: 0.01)
        try db.updateSession(pid: 1234, tool: .claude, ask: "hello", status: .idle)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        // selectedIndex defaults to 0; the lone local row is selected.
        #expect(vm.unreadSessionIds.contains(session.id))

        vm.markSelectedRowRead()
        #expect(!vm.unreadSessionIds.contains(session.id))
    }

    @Test("markSelectedRowRead on remote selection stamps lastReadAt and clears unread pill")
    @MainActor
    func markSelectedRowReadRemote() throws {
        let db = try SeshctlDatabase.temporary()
        let remote = makeRemoteForMarkRead(
            id: "cse_mark_remote",
            lastEventAt: Date(timeIntervalSinceNow: -60),
            unread: true
        )
        try db.upsertRemoteClaudeCodeSessions([remote])

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.selectedRow?.id == "cse_mark_remote")
        #expect(vm.unreadSessionIds.contains("cse_mark_remote"))

        vm.markSelectedRowRead()

        // In-memory row is patched so the pill clears immediately.
        let inMemory = vm.remoteSessions.first { $0.id == "cse_mark_remote" }!
        #expect(inMemory.lastReadAt != nil)
        #expect(!vm.unreadSessionIds.contains("cse_mark_remote"))

        // DB was actually written — refresh from disk and the row is still read.
        let persisted = try db.listRemoteClaudeCodeSessions().first!
        #expect(persisted.lastReadAt != nil)
        #expect(persisted.isUnread == false)
    }

    @Test("markSelectedRowRead with no selection is a safe no-op")
    @MainActor
    func markSelectedRowReadNone() throws {
        let db = try SeshctlDatabase.temporary()
        // Empty DB, no rows, no selection.
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.selectedRow == nil)

        // Must not crash, must not mutate state.
        vm.markSelectedRowRead()
        #expect(vm.unreadSessionIds.isEmpty)
    }

    @Test("confirmMarkAllRead clears both local and remote unread rows and stamps lastReadAt for remote")
    @MainActor
    func confirmMarkAllReadMixed() throws {
        let db = try SeshctlDatabase.temporary()

        // One local unread session.
        let local = try db.startSession(tool: .claude, directory: "/tmp", pid: 5555)
        Thread.sleep(forTimeInterval: 0.01)
        try db.updateSession(pid: 5555, tool: .claude, ask: "hi", status: .idle)

        // One remote unread session.
        let remote = makeRemoteForMarkRead(
            id: "cse_mixed_remote",
            lastEventAt: Date(timeIntervalSinceNow: -30),
            unread: true
        )
        try db.upsertRemoteClaudeCodeSessions([remote])

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.unreadSessionIds.contains(local.id))
        #expect(vm.unreadSessionIds.contains("cse_mixed_remote"))

        vm.requestMarkAllRead()
        vm.confirmMarkAllRead()

        #expect(vm.unreadSessionIds.isEmpty)
        #expect(vm.pendingMarkAllRead == false)

        // Local last_read_at updated in DB.
        let localFetched = try db.findActiveSession(pid: 5555, tool: .claude)!
        #expect(localFetched.lastReadAt != nil)

        // Remote last_read_at updated in DB and in-memory row.
        let remoteFetched = try db.listRemoteClaudeCodeSessions().first!
        #expect(remoteFetched.lastReadAt != nil)
        #expect(remoteFetched.isUnread == false)
        let inMemory = vm.remoteSessions.first { $0.id == "cse_mixed_remote" }!
        #expect(inMemory.lastReadAt != nil)
    }

    // MARK: - Bridge Dedupe Tests
    //
    // These exercise the view-model glue that composes
    // `TranscriptBridgeScanner` + `BridgeMatcher` + published bridged ID sets
    // + `activeRows`/`recentRows` filtering. The units themselves are tested
    // in `BridgeMatcherTests` / `TranscriptBridgeScannerTests`; these tests
    // pin the integration seams so someone refactoring `refresh()` or the
    // row filters can't silently regress the whole feature.

    @MainActor
    private func writeTranscript(bridgedToCseId cseId: String) throws -> String {
        let suffix = cseId.hasPrefix("cse_") ? String(cseId.dropFirst(4)) : cseId
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        let content = """
        {"type":"system","subtype":"bridge_status","url":"https://claude.ai/code/session_\(suffix)"}
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @MainActor
    private func makeBridgeRemote(id: String) -> RemoteClaudeCodeSession {
        RemoteClaudeCodeSession(
            id: id,
            title: "bridged remote",
            model: "claude-opus-4-7",
            repoUrl: "https://github.com/x/bar",
            branches: ["main"],
            status: "active",
            workerStatus: "idle",
            connectionStatus: "connected",
            lastEventAt: Date(),
            createdAt: Date(),
            unread: false,
            lastReadAt: nil,
            environmentKind: "bridge"
        )
    }

    @Test("refresh pairs a bridged local with its matching remote via the transcript scanner")
    @MainActor
    func refreshPairsBridgedPair() throws {
        let transcriptPath = try writeTranscript(bridgedToCseId: "cse_VMPAIR")
        defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

        let db = try SeshctlDatabase.temporary()
        let local = try db.startSession(tool: .claude, directory: "/tmp/x", pid: 8801)
        try db.updateSession(pid: 8801, tool: .claude, transcriptPath: transcriptPath)
        try db.upsertRemoteClaudeCodeSessions([makeBridgeRemote(id: "cse_VMPAIR")])

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.bridgedLocalIds.contains(local.id))
        #expect(vm.bridgedRemoteIds.contains("cse_VMPAIR"))
    }

    @Test("activeRows / recentRows exclude a bridged remote's id")
    @MainActor
    func bridgedRemoteHiddenFromRowSlices() throws {
        let transcriptPath = try writeTranscript(bridgedToCseId: "cse_HIDDEN")
        defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

        let db = try SeshctlDatabase.temporary()
        _ = try db.startSession(tool: .claude, directory: "/tmp/x", pid: 8802)
        try db.updateSession(pid: 8802, tool: .claude, transcriptPath: transcriptPath)

        let paired = makeBridgeRemote(id: "cse_HIDDEN")
        var unpaired = makeBridgeRemote(id: "cse_SOLO")
        unpaired.connectionStatus = "disconnected" // lands in recentRows
        try db.upsertRemoteClaudeCodeSessions([paired, unpaired])

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        let activeIds = vm.activeRows.map(\.id)
        let recentIds = vm.recentRows.map(\.id)
        #expect(!activeIds.contains("cse_HIDDEN"))
        #expect(!recentIds.contains("cse_HIDDEN"))
        // The unrelated remote should remain visible; assert something is there.
        #expect(activeIds.contains("cse_SOLO") || recentIds.contains("cse_SOLO"))
    }

    @Test("pair dissolves when the bridged local goes terminal (.completed)")
    @MainActor
    func pairDissolvesOnCompleted() throws {
        let transcriptPath = try writeTranscript(bridgedToCseId: "cse_DIES")
        defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

        let db = try SeshctlDatabase.temporary()
        _ = try db.startSession(tool: .claude, directory: "/tmp/x", pid: 8803)
        try db.updateSession(pid: 8803, tool: .claude, transcriptPath: transcriptPath)
        try db.upsertRemoteClaudeCodeSessions([makeBridgeRemote(id: "cse_DIES")])

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.bridgedRemoteIds.contains("cse_DIES"))

        // Session ends; pair should dissolve on next refresh.
        try db.endSession(pid: 8803, tool: .claude)
        vm.refresh()
        #expect(!vm.bridgedRemoteIds.contains("cse_DIES"))
        #expect(vm.bridgedLocalIds.isEmpty)

        // And the bridged remote should reappear in the row slices.
        let allVisibleIds = (vm.activeRows + vm.recentRows).map(\.id)
        #expect(allVisibleIds.contains("cse_DIES"))
    }

    @Test("remoteSessionCount counts a bridged pair exactly once")
    @MainActor
    func remoteSessionCountBridgedPairCountedOnce() throws {
        let transcriptPath = try writeTranscript(bridgedToCseId: "cse_COUNT_ONCE")
        defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

        let db = try SeshctlDatabase.temporary()
        _ = try db.startSession(tool: .claude, directory: "/tmp/x", pid: 8901)
        try db.updateSession(pid: 8901, tool: .claude, transcriptPath: transcriptPath)
        try db.upsertRemoteClaudeCodeSessions([makeBridgeRemote(id: "cse_COUNT_ONCE")])

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        // The pair contributes exactly 1 to the count (via the bridged-local leg).
        // The remote twin is in `bridgedRemoteIds` and excluded from the pure-remote leg.
        #expect(vm.remoteSessionCount == 1)
    }

    @Test("remoteSessionCount stays stable when a bridged pair dissolves")
    @MainActor
    func remoteSessionCountStableOnPairDissolve() throws {
        let transcriptPath = try writeTranscript(bridgedToCseId: "cse_DISSOLVE")
        defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

        let db = try SeshctlDatabase.temporary()
        _ = try db.startSession(tool: .claude, directory: "/tmp/x", pid: 8902)
        try db.updateSession(pid: 8902, tool: .claude, transcriptPath: transcriptPath)
        try db.upsertRemoteClaudeCodeSessions([makeBridgeRemote(id: "cse_DISSOLVE")])

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.remoteSessionCount == 1) // counted via bridged-local leg

        // Local ends → pair dissolves → the same remote now contributes via pure-remote leg.
        try db.endSession(pid: 8902, tool: .claude)
        vm.refresh()
        #expect(vm.remoteSessionCount == 1) // still 1, now via pure-remote leg
    }

    @Test("remoteSessionCount sums bridged pair + pure-remote")
    @MainActor
    func remoteSessionCountMixedBridgedAndPure() throws {
        let transcriptPath = try writeTranscript(bridgedToCseId: "cse_MIX_BRIDGED")
        defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

        let db = try SeshctlDatabase.temporary()
        _ = try db.startSession(tool: .claude, directory: "/tmp/x", pid: 8903)
        try db.updateSession(pid: 8903, tool: .claude, transcriptPath: transcriptPath)

        let bridgedRemote = makeBridgeRemote(id: "cse_MIX_BRIDGED")
        // Pure-remote session (not bridged — no matching transcript event and
        // `environmentKind` is not `"bridge"`, so `BridgeMatcher` won't consider it).
        var pureRemote = makeBridgeRemote(id: "cse_MIX_PURE")
        pureRemote.environmentKind = ""
        try db.upsertRemoteClaudeCodeSessions([bridgedRemote, pureRemote])

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        // 1 bridged pair + 1 pure-remote connected = 2
        #expect(vm.remoteSessionCount == 2)
    }

    @Test("non-Claude locals don't trigger transcript scans (tool filter)")
    @MainActor
    func nonClaudeLocalSkipsScanner() throws {
        // A Codex transcript that (implausibly) contains a bridge_status
        // event — if the tool filter works, the VM must ignore it and not
        // produce a pair, because bridging is Claude-specific.
        let transcriptPath = try writeTranscript(bridgedToCseId: "cse_SHOULDNT_MATCH")
        defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

        let db = try SeshctlDatabase.temporary()
        _ = try db.startSession(tool: .codex, directory: "/tmp/x", pid: 8804)
        try db.updateSession(pid: 8804, tool: .codex, transcriptPath: transcriptPath)
        try db.upsertRemoteClaudeCodeSessions([makeBridgeRemote(id: "cse_SHOULDNT_MATCH")])

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.bridgedLocalIds.isEmpty)
        #expect(vm.bridgedRemoteIds.isEmpty)
    }

    // MARK: - deleteSearchWord Tests

    @Test("deleteSearchWord removes last word")
    @MainActor
    func deleteSearchWordRemovesLastWord() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.enterSearch()
        vm.appendSearchCharacter("hello world")
        vm.deleteSearchWord()
        #expect(vm.searchQuery == "hello ")
    }

    @Test("deleteSearchWord removes trailing whitespace then word")
    @MainActor
    func deleteSearchWordTrailingWhitespace() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.enterSearch()
        vm.appendSearchCharacter("hello   ")
        vm.deleteSearchWord()
        #expect(vm.searchQuery == "")
    }

    @Test("deleteSearchWord on single word clears query")
    @MainActor
    func deleteSearchWordSingleWord() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.enterSearch()
        vm.appendSearchCharacter("hello")
        vm.deleteSearchWord()
        #expect(vm.searchQuery == "")
    }

    @Test("deleteSearchWord on empty query exits search")
    @MainActor
    func deleteSearchWordEmptyExitsSearch() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.enterSearch()
        vm.deleteSearchWord()
        #expect(!vm.isSearching)
    }

    // MARK: - clearSearchQuery Tests

    @Test("clearSearchQuery clears the query but stays in search mode")
    @MainActor
    func clearSearchQueryClears() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.enterSearch()
        vm.appendSearchCharacter("hello")
        vm.clearSearchQuery()
        #expect(vm.searchQuery == "")
        #expect(vm.isSearching)
        #expect(vm.selectedIndex == 0)
    }

    // MARK: - Multi-character append (paste) Tests

    @Test("appendSearchCharacter with multi-character string")
    @MainActor
    func appendMultiCharString() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.enterSearch()
        vm.appendSearchCharacter("hello world")
        #expect(vm.searchQuery == "hello world")
        #expect(vm.selectedIndex == 0)
    }

    // MARK: - Recall Search Tests

    @Test("Recall state is clean on init")
    @MainActor
    func recallStateCleanOnInit() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)

        #expect(vm.recallResults.isEmpty)
        #expect(vm.isRecallSearching == false)
        #expect(vm.recallUnavailable == false)
        #expect(vm.recallIndexingDone == nil)
    }

    @Test("exitSearch clears recall state")
    @MainActor
    func exitSearchClearsRecallState() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)

        vm.enterSearch()
        vm.appendSearchCharacter("t")
        vm.appendSearchCharacter("e")
        vm.appendSearchCharacter("s")
        vm.appendSearchCharacter("t")

        vm.exitSearch()

        #expect(vm.recallResults.isEmpty)
        #expect(vm.isRecallSearching == false)
        #expect(vm.recallIndexingDone == nil)
        #expect(vm.isSearching == false)
        #expect(vm.searchQuery == "")
    }

    /// Poll until `condition()` is true or `timeout` elapses. Used by recall tests
    /// to wait for async debounce + Task continuations to land under heavy
    /// parallel @MainActor contention (a fixed sleep is flaky on loaded CI).
    @MainActor
    private func waitForRecall(
        timeout: TimeInterval = 3.0,
        _ condition: () -> Bool
    ) async {
        let start = Date()
        while !condition() && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("recallErrorMessage is populated when search fails")
    @MainActor
    func recallErrorMessagePopulatedOnSearchFailed() async throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.recallSearchProvider = { _, _ in
            throw RecallError.searchFailed("boom: traceback line 1\ntraceback line 2")
        }
        vm.enterSearch()
        vm.appendSearchCharacter("t")

        await waitForRecall { vm.recallErrorMessage != nil }

        #expect(vm.recallErrorMessage != nil)
        #expect(vm.recallErrorMessage?.contains("Semantic search failed") == true)
        #expect(vm.recallErrorMessage?.contains("boom") == true)
        #expect(vm.recallErrorMessage?.contains("traceback line 2") == false)
        #expect(vm.isRecallSearching == false)
        #expect(vm.recallUnavailable == false)
    }

    @Test("recallErrorMessage is populated on timeout")
    @MainActor
    func recallErrorMessagePopulatedOnTimeout() async throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.recallSearchProvider = { _, _ in
            throw RecallError.timeout
        }
        vm.enterSearch()
        vm.appendSearchCharacter("t")

        await waitForRecall { vm.recallErrorMessage != nil }

        #expect(vm.recallErrorMessage == "Semantic search timed out")
        #expect(vm.isRecallSearching == false)
        #expect(vm.recallUnavailable == false)
    }

    @Test("recallErrorMessage stays nil for notInstalled (uses recallUnavailable instead)")
    @MainActor
    func recallErrorMessageNilOnNotInstalled() async throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.recallSearchProvider = { _, _ in
            throw RecallError.notInstalled
        }
        vm.enterSearch()
        vm.appendSearchCharacter("t")

        await waitForRecall { vm.recallUnavailable }

        #expect(vm.recallErrorMessage == nil)
        #expect(vm.recallUnavailable == true)
    }

    @Test("exitSearch clears recallErrorMessage")
    @MainActor
    func recallErrorMessageClearedByExitSearch() async throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.recallSearchProvider = { _, _ in
            throw RecallError.searchFailed("boom")
        }
        vm.enterSearch()
        vm.appendSearchCharacter("t")

        await waitForRecall { vm.recallErrorMessage != nil }
        #expect(vm.recallErrorMessage != nil)

        vm.exitSearch()
        #expect(vm.recallErrorMessage == nil)
    }

    @Test("Backspacing query to empty clears recallErrorMessage")
    @MainActor
    func recallErrorMessageClearedByBackspaceToEmpty() async throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.recallSearchProvider = { _, _ in
            throw RecallError.searchFailed("boom")
        }
        vm.enterSearch()
        vm.appendSearchCharacter("a")
        vm.appendSearchCharacter("b")

        await waitForRecall { vm.recallErrorMessage != nil }
        #expect(vm.recallErrorMessage != nil)

        // Two backspaces: "ab" -> "a" -> "". The second one trips the
        // empty-query early-return in triggerRecallSearch.
        vm.deleteSearchCharacter()
        vm.deleteSearchCharacter()

        // Polling because the second delete still calls triggerRecallSearch
        // which dispatches a debounceTask. The error should be cleared
        // synchronously inside the empty-query guard, but poll briefly
        // to be robust to any future restructuring.
        await waitForRecall(timeout: 0.5) { vm.recallErrorMessage == nil }
        #expect(vm.recallErrorMessage == nil)
        #expect(vm.searchQuery == "")
        #expect(vm.isSearching == true)  // still in search mode
    }

    @Test("clearSearchQuery clears recallErrorMessage")
    @MainActor
    func recallErrorMessageClearedByClearSearchQuery() async throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.recallSearchProvider = { _, _ in
            throw RecallError.searchFailed("boom")
        }
        vm.enterSearch()
        vm.appendSearchCharacter("t")

        await waitForRecall { vm.recallErrorMessage != nil }
        #expect(vm.recallErrorMessage != nil)

        vm.clearSearchQuery()
        #expect(vm.recallErrorMessage == nil)
        #expect(vm.searchQuery == "")
    }

    @Test("New search clears prior recallErrorMessage")
    @MainActor
    func recallErrorMessageClearedByNewSearch() async throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.recallSearchProvider = { _, _ in
            throw RecallError.searchFailed("oldboom")
        }
        vm.enterSearch()
        vm.appendSearchCharacter("t")

        await waitForRecall { vm.recallErrorMessage != nil }
        #expect(vm.recallErrorMessage != nil)

        // Swap in a successful provider, then trigger a new search by changing the query.
        vm.recallSearchProvider = { _, _ in
            RecallSearchResponse(results: [], indexingCount: nil)
        }
        vm.appendSearchCharacter("x")

        await waitForRecall { vm.recallErrorMessage == nil && !vm.isRecallSearching }
        #expect(vm.recallErrorMessage == nil)
    }

    @Test("firstLine truncates long error messages with ellipsis")
    @MainActor
    func firstLineTruncatesLongMessages() async throws {
        let longLineOne = String(repeating: "a", count: 300)
        let longMessage = "\(longLineOne)\nsecond line content"

        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.recallSearchProvider = { _, _ in
            throw RecallError.searchFailed(longMessage)
        }
        vm.enterSearch()
        vm.appendSearchCharacter("t")

        await waitForRecall { vm.recallErrorMessage != nil }

        let message = try #require(vm.recallErrorMessage)
        #expect(message.count < longMessage.count)
        #expect(message.contains("…"))
        #expect(message.contains("second line content") == false)
    }

    @Test("selectedRecallResult returns nil when not searching")
    @MainActor
    func selectedRecallResultNilWhenNotSearching() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.selectedRecallResult == nil)
    }

    @Test("selectedRecallResult returns nil when selection is in sessions section")
    @MainActor
    func selectedRecallResultNilInSessionSection() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        vm.enterSearch()

        #expect(vm.selectedIndex == 0)
        #expect(vm.selectedRecallResult == nil)
    }

    @Test("totalResultCount equals session count when not searching")
    @MainActor
    func totalResultCountNoSearch() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)
        try db.startSession(tool: .gemini, directory: "/tmp/b", pid: 2)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.totalResultCount == 2)
    }

    @Test("moveToBottom respects totalResultCount when searching")
    @MainActor
    func moveToBottomWithSearch() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)
        try db.startSession(tool: .gemini, directory: "/tmp/b", pid: 2)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        vm.enterSearch()

        // Without recall results, bottom should be last session
        vm.moveToBottom()
        #expect(vm.selectedIndex == 1)
    }

    // MARK: - Session Lookup for Recall Results

    @Test("session(for:) finds matching active session")
    @MainActor
    func sessionForRecallResultFindsActive() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(
            tool: .claude, directory: "/tmp/project", pid: 1234,
            conversationId: "conv-abc"
        )

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        let result = RecallResult(
            agent: "claude", role: "user", sessionId: "conv-abc",
            project: "/tmp/project", timestamp: Date().timeIntervalSince1970,
            score: 0.9, resumeCmd: "claude --resume conv-abc", text: "test"
        )

        let found = vm.session(for: result)
        #expect(found?.id == session.id)
    }

    @Test("session(for:) finds matching inactive session")
    @MainActor
    func sessionForRecallResultFindsInactive() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(
            tool: .claude, directory: "/tmp/project", pid: 1234,
            conversationId: "conv-abc"
        )
        try db.endSession(pid: 1234, tool: .claude)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        let result = RecallResult(
            agent: "claude", role: "user", sessionId: "conv-abc",
            project: "/tmp/project", timestamp: Date().timeIntervalSince1970,
            score: 0.9, resumeCmd: "claude --resume conv-abc", text: "test"
        )

        let found = vm.session(for: result)
        #expect(found?.id == session.id)
    }

    @Test("session(for:) returns nil when no match")
    @MainActor
    func sessionForRecallResultNilWhenNoMatch() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/project", pid: 1234)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        let result = RecallResult(
            agent: "claude", role: "user", sessionId: "no-such-conv",
            project: "/tmp/project", timestamp: Date().timeIntervalSince1970,
            score: 0.9, resumeCmd: "claude --resume no-such-conv", text: "test"
        )

        #expect(vm.session(for: result) == nil)
    }

    // MARK: - Tree Mode / View Toggle Tests

    private func makeIsolatedDefaults(_ name: String) -> (UserDefaults, String) {
        let suiteName = "seshctl.tests.\(name).\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func setRepo(
        _ db: SeshctlDatabase, pid: Int, repo: String?
    ) throws {
        try db.dbPool.write { conn in
            try conn.execute(
                sql: "UPDATE sessions SET git_repo_name = ? WHERE pid = ?",
                arguments: [repo, pid]
            )
        }
    }

    @Test("toggleViewMode preserves selected session by id across modes")
    @MainActor
    func toggleViewModePreservesSelection() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/alpha", pid: 1)
        try setRepo(db, pid: 1, repo: "alpha")
        try db.startSession(tool: .claude, directory: "/tmp/beta", pid: 2)
        try setRepo(db, pid: 2, repo: "beta")
        try db.startSession(tool: .gemini, directory: "/tmp/gamma", pid: 3)
        try setRepo(db, pid: 3, repo: "gamma")

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()

        // List mode default: pick the 2nd session.
        vm.selectedIndex = 1
        let targetId = vm.selectedSession?.id
        #expect(targetId != nil)

        // Toggle to tree mode.
        vm.toggleViewMode()
        #expect(vm.isTreeMode == true)
        #expect(vm.selectedSession?.id == targetId)

        // Toggle back.
        vm.toggleViewMode()
        #expect(vm.isTreeMode == false)
        #expect(vm.selectedSession?.id == targetId)
    }

    @Test("toggleViewMode falls back to index 0 when session missing from new ordering")
    @MainActor
    func toggleViewModeFallbackWhenMissing() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        // Active session.
        try db.startSession(tool: .claude, directory: "/tmp/active", pid: 1)
        try setRepo(db, pid: 1, repo: "active")
        // Recent (completed) session.
        try db.startSession(tool: .gemini, directory: "/tmp/recent", pid: 2)
        try setRepo(db, pid: 2, repo: "recent")
        try db.endSession(pid: 2, tool: .gemini)

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()

        // Recents are gated to search; enter search so both rows are
        // visible, then pick the recent one (index 1 in active+recent).
        vm.enterSearch()
        let recentIndex = vm.filteredRows.firstIndex { !$0.isActive }!
        vm.selectedIndex = recentIndex

        // Toggle to tree — recents are excluded, so the selection should fall back to 0.
        vm.toggleViewMode()
        #expect(vm.isTreeMode == true)
        #expect(vm.selectedIndex == 0)
        #expect(vm.selectedSession?.isActive == true)
    }

    @Test("toggleViewMode sets selectedIndex to -1 when new ordering is empty")
    @MainActor
    func toggleViewModeEmptyNextOrdering() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        // Only a recent session; active list is empty.
        try db.startSession(tool: .claude, directory: "/tmp/r", pid: 1)
        try db.endSession(pid: 1, tool: .claude)

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        // Recents are gated to search now, so make them visible by
        // entering search before selecting one.
        vm.enterSearch()
        vm.selectedIndex = 0
        #expect(vm.selectedSession != nil)

        // Toggle to tree — no active sessions, tree is empty.
        vm.toggleViewMode()
        #expect(vm.isTreeMode == true)
        #expect(vm.selectedIndex == -1)
        #expect(vm.selectedSession == nil)
    }

    @Test("isTreeMode round-trips through injected UserDefaults")
    @MainActor
    func isTreeModePersists() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()

        let vm1 = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        #expect(vm1.isTreeMode == false)
        vm1.isTreeMode = true

        // New viewmodel with the same store — should read the persisted value.
        let vm2 = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        #expect(vm2.isTreeMode == true)

        vm2.isTreeMode = false
        let vm3 = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        #expect(vm3.isTreeMode == false)
    }

    @Test("Entering search from tree mode preserves isTreeMode across search")
    @MainActor
    func enterSearchFromTreeMode() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        vm.isTreeMode = true

        // Simulate AppDelegate's `/` flow: just enter search; tree mode must
        // not be mutated (the view gates on `isTreeMode && !isSearching`).
        vm.enterSearch()

        #expect(vm.isTreeMode == true)
        #expect(vm.isSearching == true)

        // Exiting search leaves tree mode intact.
        vm.exitSearch()
        #expect(vm.isTreeMode == true)
        #expect(vm.isSearching == false)

        // UserDefaults still reflects tree mode (no silent write-through).
        #expect(defaults.bool(forKey: "seshctl.isTreeMode") == true)
    }

    // MARK: - Inbox-aware reset on panel open

    @Test("applyInboxAwareResetIfNeeded does nothing in list mode")
    @MainActor
    func inboxResetNoOpInListMode() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        #expect(vm.isTreeMode == false)

        // Even with a long-elapsed lastClosedAt, list mode should not be touched.
        let now = Date(timeIntervalSince1970: 1_000_000)
        vm.recordPanelClose(now: Date(timeIntervalSince1970: 1_000))
        let flipped = vm.applyInboxAwareResetIfNeeded(now: now)
        #expect(flipped == false)
        #expect(vm.isTreeMode == false)
    }

    @Test("applyInboxAwareResetIfNeeded does nothing within burst window (<= 10s since lastClosedAt)")
    @MainActor
    func inboxResetNoOpWithinBurstWindow() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.isTreeMode = true

        let close = Date(timeIntervalSince1970: 1_000_000)
        vm.recordPanelClose(now: close)

        // Exactly at the boundary (10s): still within window.
        let atBoundary = close.addingTimeInterval(10)
        #expect(vm.applyInboxAwareResetIfNeeded(now: atBoundary) == false)
        #expect(vm.isTreeMode == true)

        // Well within window.
        let within = close.addingTimeInterval(3)
        #expect(vm.applyInboxAwareResetIfNeeded(now: within) == false)
        #expect(vm.isTreeMode == true)
    }

    @Test("applyInboxAwareResetIfNeeded flips to list mode when > 10s elapsed, without persisting")
    @MainActor
    func inboxResetFlipsTransientlyAfterBurstWindow() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.isTreeMode = true
        #expect(defaults.bool(forKey: "seshctl.isTreeMode") == true)

        let close = Date(timeIntervalSince1970: 1_000_000)
        vm.recordPanelClose(now: close)

        // 10.001s elapsed — just past the boundary.
        let after = close.addingTimeInterval(10.001)
        let flipped = vm.applyInboxAwareResetIfNeeded(now: after)
        #expect(flipped == true)
        #expect(vm.isTreeMode == false)
        // The critical invariant: persisted tree-mode preference is untouched.
        #expect(defaults.bool(forKey: "seshctl.isTreeMode") == true)
    }

    @Test("recordPanelClose writes lastClosedAt to defaults")
    @MainActor
    func recordPanelCloseWritesDefaults() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)

        let now = Date(timeIntervalSince1970: 1_234_567.5)
        vm.recordPanelClose(now: now)
        #expect(defaults.double(forKey: "seshctl.lastClosedAt") == 1_234_567.5)
    }

    @Test("After a transient flip, toggleViewMode restores tree mode AND persists it")
    @MainActor
    func toggleViewModeAfterTransientFlipPersists() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        vm.isTreeMode = true
        #expect(defaults.bool(forKey: "seshctl.isTreeMode") == true)

        let close = Date(timeIntervalSince1970: 1_000_000)
        vm.recordPanelClose(now: close)
        let flipped = vm.applyInboxAwareResetIfNeeded(now: close.addingTimeInterval(60))
        #expect(flipped == true)
        #expect(vm.isTreeMode == false)
        // Persistence unchanged by the transient flip.
        #expect(defaults.bool(forKey: "seshctl.isTreeMode") == true)

        // User presses `v` — goes back to tree mode and this time persistence writes.
        vm.toggleViewMode()
        #expect(vm.isTreeMode == true)
        #expect(defaults.bool(forKey: "seshctl.isTreeMode") == true)

        // Press `v` again — writes list mode this time.
        vm.toggleViewMode()
        #expect(vm.isTreeMode == false)
        #expect(defaults.bool(forKey: "seshctl.isTreeMode") == false)
    }

    @Test("First open after install (no lastClosedAt stored) flips to list when in tree mode")
    @MainActor
    func inboxResetFirstOpenAfterInstall() throws {
        // Documents the edge case: with no stored `lastClosedAt`, the default
        // value read from UserDefaults is 0 (epoch), so `now - 0` is always
        // far greater than the 10s burst window, and we treat the open as a
        // fresh inbox glance and flip to list mode.
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.isTreeMode = true
        #expect(defaults.object(forKey: "seshctl.lastClosedAt") == nil)

        let flipped = vm.applyInboxAwareResetIfNeeded()
        #expect(flipped == true)
        #expect(vm.isTreeMode == false)
        // Persistence untouched.
        #expect(defaults.bool(forKey: "seshctl.isTreeMode") == true)
    }

    @Test("applyInboxAwareResetIfNeeded preserves selectedIndex across the flip")
    @MainActor
    func inboxResetPreservesSelectedIndex() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        for i in 1...5 { try db.startSession(tool: .claude, directory: "/tmp/\(i)", pid: i) }

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.isTreeMode = true
        vm.refresh()

        let middle = 2
        vm.selectedIndex = middle

        let close = Date(timeIntervalSince1970: 1_000_000)
        vm.recordPanelClose(now: close)
        let after = close.addingTimeInterval(60)
        let flipped = vm.applyInboxAwareResetIfNeeded(now: after, burstWindow: 10)
        #expect(flipped == true)
        // selectedIndex is intentionally preserved by the transient flip.
        // (The session under it may differ because orderedSessions changed shape.)
        #expect(vm.selectedIndex == middle)
    }

    @Test("applyInboxAwareResetIfNeeded flips just past 10.0s boundary")
    @MainActor
    func inboxResetFlipsJustPastBoundary() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.isTreeMode = true

        let close = Date(timeIntervalSince1970: 1_000_000)
        vm.recordPanelClose(now: close)

        // Just past 10.0s — float-clarity boundary check.
        let justPast = close.addingTimeInterval(10.0001)
        let flipped = vm.applyInboxAwareResetIfNeeded(now: justPast)
        #expect(flipped == true)
        #expect(vm.isTreeMode == false)
    }

    @Test("applyInboxAwareResetIfNeeded does not flip on negative elapsed (clock skew)")
    @MainActor
    func inboxResetNoFlipOnNegativeElapsed() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.isTreeMode = true

        // Simulate a clock skew: lastClosedAt is in the future relative to now.
        let close = Date(timeIntervalSince1970: 2_000_000)
        vm.recordPanelClose(now: close)
        let now = Date(timeIntervalSince1970: 1_000_000) // now < lastClosedAt

        let flipped = vm.applyInboxAwareResetIfNeeded(now: now)
        #expect(flipped == false)
        #expect(vm.isTreeMode == true)
    }

    @Test("toggleViewMode clears pendingKillSessionId and pendingMarkAllRead")
    @MainActor
    func toggleViewModeClearsPendingState() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()

        let sessionId = vm.localOrderedSessions.first!.id
        vm.pendingKillSessionId = sessionId
        vm.pendingMarkAllRead = true

        vm.toggleViewMode()

        #expect(vm.pendingKillSessionId == nil)
        #expect(vm.pendingMarkAllRead == false)
    }

    // MARK: - Sentinel preservation (empty ordering) Tests

    @Test("Move/page/gg/G preserve selectedIndex = -1 when ordering is empty")
    @MainActor
    func sentinelPreservedOnEmpty() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        #expect(vm.localOrderedSessions.isEmpty)

        vm.selectedIndex = -1

        vm.moveSelectionUp()
        #expect(vm.selectedIndex == -1)

        vm.moveSelectionDown()
        #expect(vm.selectedIndex == -1)

        vm.moveSelectionBy(-10)
        #expect(vm.selectedIndex == -1)

        vm.moveSelectionBy(10)
        #expect(vm.selectedIndex == -1)

        vm.moveToTop()
        #expect(vm.selectedIndex == -1)

        vm.moveToBottom()
        #expect(vm.selectedIndex == -1)
    }

    // MARK: - Group jump (h/l) tests

    /// Build a tree-mode viewmodel with three groups:
    ///   alpha [session 1]
    ///   beta  [session 2, session 3]
    ///   gamma [session 4]
    @MainActor
    private func makeTreeViewModelWithGroups(
        _ name: String
    ) throws -> (SessionListViewModel, String) {
        let (defaults, suite) = makeIsolatedDefaults(name)
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/alpha/a1", pid: 1)
        try setRepo(db, pid: 1, repo: "alpha")
        try db.startSession(tool: .claude, directory: "/tmp/beta/b1", pid: 2)
        try setRepo(db, pid: 2, repo: "beta")
        try db.startSession(tool: .claude, directory: "/tmp/beta/b2", pid: 3)
        try setRepo(db, pid: 3, repo: "beta")
        try db.startSession(tool: .gemini, directory: "/tmp/gamma/g1", pid: 4)
        try setRepo(db, pid: 4, repo: "gamma")

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        vm.isTreeMode = true
        return (vm, suite)
    }

    @Test("jumpToNextGroup moves selection to first session of next group")
    @MainActor
    func jumpToNextGroupMovesToNextGroup() throws {
        let (vm, suite) = try makeTreeViewModelWithGroups(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Start at alpha's only session (index 0).
        vm.selectedIndex = 0
        vm.jumpToNextGroup()
        // Next group is beta; its first session is at index 1.
        #expect(vm.selectedIndex == 1)

        // From the second session of beta (index 2), next group is gamma at index 3.
        vm.selectedIndex = 2
        vm.jumpToNextGroup()
        #expect(vm.selectedIndex == 3)
    }

    @Test("jumpToNextGroup at last group is a no-op")
    @MainActor
    func jumpToNextGroupAtLastGroupNoOp() throws {
        let (vm, suite) = try makeTreeViewModelWithGroups(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // gamma is the last group, sole session at index 3.
        vm.selectedIndex = 3
        vm.jumpToNextGroup()
        #expect(vm.selectedIndex == 3)
    }

    @Test("jumpToPreviousGroup from mid-group jumps to first session of current group")
    @MainActor
    func jumpToPreviousGroupFromMidGroup() throws {
        let (vm, suite) = try makeTreeViewModelWithGroups(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // beta's second session is at index 2; jumping back should land on beta's first (index 1).
        vm.selectedIndex = 2
        vm.jumpToPreviousGroup()
        #expect(vm.selectedIndex == 1)
    }

    @Test("jumpToPreviousGroup from first session of group jumps to previous group")
    @MainActor
    func jumpToPreviousGroupFromGroupStart() throws {
        let (vm, suite) = try makeTreeViewModelWithGroups(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // beta's first session is at index 1; jumping back should land on alpha's first (index 0).
        vm.selectedIndex = 1
        vm.jumpToPreviousGroup()
        #expect(vm.selectedIndex == 0)
    }

    @Test("jumpToPreviousGroup at first group is a no-op")
    @MainActor
    func jumpToPreviousGroupAtFirstGroupNoOp() throws {
        let (vm, suite) = try makeTreeViewModelWithGroups(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        vm.selectedIndex = 0
        vm.jumpToPreviousGroup()
        #expect(vm.selectedIndex == 0)
    }

    @Test("jumpToNextGroup and jumpToPreviousGroup preserve -1 sentinel on empty tree")
    @MainActor
    func jumpGroupPreservesSentinel() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        vm.isTreeMode = true
        vm.selectedIndex = -1

        vm.jumpToNextGroup()
        #expect(vm.selectedIndex == -1)

        vm.jumpToPreviousGroup()
        #expect(vm.selectedIndex == -1)
    }

    @Test("jumpToNextGroup with no selection is a no-op")
    @MainActor
    func jumpToNextGroupWithNoSelectionIsNoOp() throws {
        let (vm, suite) = try makeTreeViewModelWithGroups(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Tree is non-empty, but no selection is active.
        vm.selectedIndex = -1
        vm.jumpToNextGroup()
        #expect(vm.selectedIndex == -1)
    }

    @Test("jumpToPreviousGroup with no selection is a no-op")
    @MainActor
    func jumpToPreviousGroupWithNoSelectionIsNoOp() throws {
        let (vm, suite) = try makeTreeViewModelWithGroups(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Tree is non-empty, but no selection is active.
        vm.selectedIndex = -1
        vm.jumpToPreviousGroup()
        #expect(vm.selectedIndex == -1)
    }

    @Test("jumpToNextGroup and jumpToPreviousGroup are no-ops in list mode")
    @MainActor
    func jumpGroupNoOpInListMode() throws {
        let (vm, suite) = try makeTreeViewModelWithGroups(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        vm.isTreeMode = false
        vm.selectedIndex = 2
        vm.jumpToNextGroup()
        #expect(vm.selectedIndex == 2)

        vm.jumpToPreviousGroup()
        #expect(vm.selectedIndex == 2)
    }

    // MARK: - hasMultipleAgentTypes

    @Test("hasMultipleAgentTypes is false when only one agent kind is visible")
    @MainActor
    func hasMultipleAgentTypesSingleKind() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)
        try db.startSession(tool: .claude, directory: "/tmp/b", pid: 2)

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()

        #expect(vm.hasMultipleAgentTypes == false)
    }

    @Test("hasMultipleAgentTypes is true when claude and gemini are both visible")
    @MainActor
    func hasMultipleAgentTypesClaudePlusGemini() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)
        try db.startSession(tool: .gemini, directory: "/tmp/b", pid: 2)

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()

        #expect(vm.hasMultipleAgentTypes == true)
    }

    @Test("hasMultipleAgentTypes is true when claude and codex are both visible")
    @MainActor
    func hasMultipleAgentTypesClaudePlusCodex() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)
        try db.startSession(tool: .codex, directory: "/tmp/b", pid: 2)

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()

        #expect(vm.hasMultipleAgentTypes == true)
    }

    /// Empty visible list — defensive: no badges to suppress, but the
    /// answer must still be `false` so callers don't render an artifact.
    @Test("hasMultipleAgentTypes is false when there are no rows")
    @MainActor
    func hasMultipleAgentTypesEmpty() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()

        #expect(vm.hasMultipleAgentTypes == false)
    }

    /// Source-filter awareness: with one local Codex + one remote Claude
    /// in the DB, `.all` sees both kinds and `.localOnly` hides the
    /// remote, collapsing the result to a single kind.
    /// `hasMultipleAgentTypes` reads `orderedRows`, which respects the
    /// filter — so toggling source-only modes shouldn't surface a badge
    /// for an agent kind the user has filtered out.
    @Test("hasMultipleAgentTypes respects sourceFilter — localOnly hides remote-only kinds")
    @MainActor
    func hasMultipleAgentTypesRespectsSourceFilter() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .codex, directory: "/tmp/c", pid: 1)
        try db.upsertRemoteClaudeCodeSessions([Self.makeRemoteForBadge(id: "cse_filter")])

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        // .all → local Codex + remote Claude → two kinds.
        #expect(vm.sourceFilter == .all)
        #expect(vm.hasMultipleAgentTypes == true)

        vm.sourceFilter = .localOnly
        vm.refresh()
        // .localOnly → remote dropped → only Codex remains → one kind.
        #expect(vm.hasMultipleAgentTypes == false)

        vm.sourceFilter = .remoteOnly
        vm.refresh()
        // .remoteOnly → local Codex dropped → only Claude remote remains → one kind.
        #expect(vm.hasMultipleAgentTypes == false)
    }

    /// Pins the `case .remote: seen.insert(.claude)` arm: a fleet of
    /// remote-only sessions has exactly one agent kind, regardless of
    /// how many remote rows are present.
    @Test("hasMultipleAgentTypes is false with two remote-only sessions")
    @MainActor
    func hasMultipleAgentTypesTwoRemoteSessions() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        try db.upsertRemoteClaudeCodeSessions([
            Self.makeRemoteForBadge(id: "cse_a"),
            Self.makeRemoteForBadge(id: "cse_b"),
        ])

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()

        #expect(vm.hasMultipleAgentTypes == false)
    }

    /// Pins the cross-source contract: the `.remote` arm contributes a
    /// `.claude` kind, so a local Codex + remote Claude is two kinds.
    @Test("hasMultipleAgentTypes is true with one local Codex and one remote Claude")
    @MainActor
    func hasMultipleAgentTypesLocalCodexPlusRemote() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .codex, directory: "/tmp/c", pid: 1)
        try db.upsertRemoteClaudeCodeSessions([Self.makeRemoteForBadge(id: "cse_xkind")])

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()

        #expect(vm.hasMultipleAgentTypes == true)
    }

    /// Local-helper for the badge tests above. Sessions are fresh and
    /// connected so they materialize as visible rows under the default
    /// `sourceFilter == .all`.
    private static func makeRemoteForBadge(id: String) -> RemoteClaudeCodeSession {
        RemoteClaudeCodeSession(
            id: id,
            title: "Remote",
            model: "claude-opus-4-7",
            repoUrl: nil,
            branches: [],
            status: "active",
            workerStatus: "idle",
            connectionStatus: "connected",
            lastEventAt: Date(),
            createdAt: Date(),
            unread: false
        )
    }

    // MARK: - filteredRows recent-row gating

    /// Default list view: closed/disconnected sessions are filtered out
    /// of `filteredRows`, even when they remain selectable via direct
    /// access to `recentRows` / `localRecentSessions`.
    @Test("filteredRows hides recent rows by default in list mode")
    @MainActor
    func filteredRowsHidesRecentByDefault() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        let active = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)
        try db.startSession(tool: .claude, directory: "/tmp/r", pid: 2)
        try db.endSession(pid: 2, tool: .claude)

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()

        #expect(vm.isTreeMode == false)
        #expect(vm.isSearching == false)
        // Recent row exists in the underlying data but is excluded from
        // the rendered list.
        #expect(vm.recentRows.count == 1)
        #expect(vm.filteredRows.count == 1)
        #expect(vm.filteredRows.first?.id == active.id)
    }

    /// Search exception: the moment `isSearching` flips on, recent rows
    /// rejoin so the user can find a historical session by title /
    /// repo / branch.
    @Test("filteredRows includes recent rows while isSearching")
    @MainActor
    func filteredRowsIncludesRecentDuringSearch() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)
        try db.startSession(tool: .claude, directory: "/tmp/r", pid: 2)
        try db.endSession(pid: 2, tool: .claude)

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        #expect(vm.filteredRows.count == 1)

        vm.enterSearch()
        // Empty search query — but `isSearching` is true, so recents
        // rejoin the visible list.
        #expect(vm.filteredRows.count == 2)

        vm.exitSearch()
        // Back to default: recents hidden again.
        #expect(vm.filteredRows.count == 1)
    }

    /// Tree mode already filtered to active rows pre-change; the new
    /// gating must not regress that path.
    @Test("filteredRows in tree mode stays active-only regardless of search")
    @MainActor
    func filteredRowsTreeModeUnaffected() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)
        try db.startSession(tool: .claude, directory: "/tmp/r", pid: 2)
        try db.endSession(pid: 2, tool: .claude)

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        vm.isTreeMode = true

        // Tree mode flattens the tree groups (active rows only).
        #expect(vm.filteredRows.count == 1)
        #expect(vm.filteredRows.allSatisfy { $0.isActive })

        // The tree-mode branch wins over the search branch in
        // `filteredRows`, so flipping `isSearching` must not surface the
        // closed row.
        vm.enterSearch()
        #expect(vm.filteredRows.count == 1)
        #expect(vm.filteredRows.allSatisfy { $0.isActive })
    }

    /// Pins the cross-feature contract: `hasMultipleAgentTypes` reads
    /// `orderedRows` (== `filteredRows`), so closed sessions of a
    /// different agent kind no longer count toward the badge gate when
    /// they're hidden by the recent-row gating. A single active Claude
    /// + a closed Gemini → only Claude is visible → no badge.
    @Test("hasMultipleAgentTypes ignores closed sessions in default view")
    @MainActor
    func hasMultipleAgentTypesIgnoresClosedSessions() throws {
        let (defaults, suite) = makeIsolatedDefaults(#function)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1)
        try db.startSession(tool: .gemini, directory: "/tmp/g", pid: 2)
        try db.endSession(pid: 2, tool: .gemini)

        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        // Default view: closed Gemini is hidden, only the active Claude
        // is visible → single kind.
        #expect(vm.hasMultipleAgentTypes == false)

        // Search re-surfaces the closed Gemini, so two kinds are now
        // visible.
        vm.enterSearch()
        #expect(vm.hasMultipleAgentTypes == true)
    }

    // MARK: - Away Summary Integration Tests
    //
    // These pin the end-to-end glue from `SessionListViewModel.refresh()`
    // through `cachedAwaySummary(for:)` / `TranscriptAwaySummaryScanner`
    // into the published `awaySummariesById` map that row views consume.
    // The scanner unit is covered in `TranscriptAwaySummaryScannerTests`;
    // here we exercise the integration seams so a refactor of `refresh()`
    // or the cache-population block can't silently regress the
    // user-reported "stale recap" bug.
    //
    // Fixture pattern mirrors `writeTranscript(bridgedToCseId:)` above:
    // JSONL is written to a `NSTemporaryDirectory()` temp file and the
    // path is plumbed through `db.updateSession(..., transcriptPath:)`.
    // The fixture body is inlined per-test rather than factored into a
    // helper — recap fixtures vary more than bridge fixtures do.
    //
    // The recap-canonical shape is documented in
    // `TranscriptAwaySummaryScannerTests`; we use minimal valid records
    // here.

    @Test("awaySummariesById populated from Claude transcript")
    @MainActor
    func awaySummariesById_populatedFromClaudeTranscript() throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        let content = """
        {"type":"system","subtype":"away_summary","content":"Shipped two PRs. (disable recaps in /config)","timestamp":"2026-05-06T17:48:04.022Z","sessionId":"abc","cwd":"/work"}
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pid: Int = 9001
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/x", pid: pid)
        try db.updateSession(pid: pid, tool: .claude, transcriptPath: path)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        // The trailing parenthetical is stripped by the scanner.
        #expect(vm.awaySummariesById[session.id] == "Shipped two PRs.")
    }

    @Test("awaySummariesById empty for non-Claude tool")
    @MainActor
    func awaySummariesById_emptyForNonClaudeTool() throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        let content = """
        {"type":"system","subtype":"away_summary","content":"Shipped two PRs.","timestamp":"2026-05-06T17:48:04.022Z","sessionId":"abc","cwd":"/work"}
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pid: Int = 9002
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .codex, directory: "/tmp/x", pid: pid)
        try db.updateSession(pid: pid, tool: .codex, transcriptPath: path)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        // The `.claude`-only guard in `cachedAwaySummary` short-circuits
        // before touching the filesystem, so non-Claude sessions never
        // land in the map.
        #expect(vm.awaySummariesById[session.id] == nil)
    }

    @Test("awaySummariesById empty when session has no transcriptPath")
    @MainActor
    func awaySummariesById_emptyWhenNoTranscriptPath() throws {
        let pid: Int = 9003
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/x", pid: pid)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(session.transcriptPath == nil)
        #expect(vm.awaySummariesById[session.id] == nil)
    }

    @Test("awaySummariesById omits entry when recap is stale")
    @MainActor
    func awaySummariesById_fallsThroughWhenRecapIsStale() throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        // A user turn lands after the recap → scanner returns nil, VM
        // should omit the entry so row preview falls through to
        // lastReply/lastAsk.
        let content = """
        {"type":"system","subtype":"away_summary","content":"Shipped two PRs.","timestamp":"2026-05-06T17:48:04.022Z","sessionId":"abc","cwd":"/work"}
        {"type":"user","message":{"role":"user","content":"new turn"},"timestamp":"2026-05-06T17:55:00.000Z","sessionId":"abc"}
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pid: Int = 9004
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/x", pid: pid)
        try db.updateSession(pid: pid, tool: .claude, transcriptPath: path)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.awaySummariesById[session.id] == nil)
    }

    @Test("awaySummariesById re-scans after the transcript file is rewritten")
    @MainActor
    func awaySummariesById_rescansAfterTranscriptRewrite() throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let firstContent = """
        {"type":"system","subtype":"away_summary","content":"First recap.","timestamp":"2026-05-06T17:48:04.022Z","sessionId":"abc","cwd":"/work"}
        """
        try firstContent.write(toFile: path, atomically: true, encoding: .utf8)

        let pid: Int = 9005
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/x", pid: pid)
        try db.updateSession(pid: pid, tool: .claude, transcriptPath: path)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.awaySummariesById[session.id] == "First recap.")

        // Rewrite the JSONL with a different recap, then explicitly bump
        // the file's mtime to dodge macOS's 1-second mtime granularity
        // (avoids same-second flakiness without needing a real sleep).
        // If the cache keys on mtime correctly, the second refresh picks
        // up "Second recap."; if the cache always serves the stale value,
        // it stays on "First recap." and this test fails.
        let secondContent = """
        {"type":"system","subtype":"away_summary","content":"Second recap.","timestamp":"2026-05-06T17:55:00.000Z","sessionId":"abc","cwd":"/work"}
        """
        try secondContent.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: path
        )

        vm.refresh()
        #expect(vm.awaySummariesById[session.id] == "Second recap.")
    }

    // MARK: - Row-reorder behavior

    @Test("Selection follows the row across a refresh-driven reorder")
    @MainActor
    func selectionFollowsRowAcrossReorder() throws {
        let db = try SeshctlDatabase.temporary()
        // Insert B first so its updated_at is older. Insert A second so A
        // sorts to the top of the desc-by-updatedAt list.
        try db.startSession(tool: .gemini, directory: "/tmp/b", pid: 2222)
        Thread.sleep(forTimeInterval: 0.01)
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1111)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        // Sanity: A (pid 1111) is at index 0, B (pid 2222) at index 1.
        #expect(vm.selectedIndex == 0)
        let aId = vm.selectedSession?.id
        #expect(vm.selectedSession?.pid == 1111)

        // Bump B's updated_at so B sorts above A on the next refresh.
        Thread.sleep(forTimeInterval: 0.01)
        try db.updateSession(pid: 2222, tool: .gemini, ask: "hi", status: .idle)
        vm.refresh()

        // A has moved to index 1; selection should have followed.
        #expect(vm.selectedIndex == 1)
        #expect(vm.selectedSession?.id == aId)
        #expect(vm.selectedSession?.pid == 1111)
    }

    @Test("panelDidShow stamps lastPanelShownAt to ~now")
    @MainActor
    func panelDidShowStampsTimestamp() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false)

        // Default is .distantPast — far enough in the past that the
        // first-open animation gate would unconditionally animate.
        #expect(vm.lastPanelShownAt == .distantPast)

        let before = Date()
        vm.panelDidShow()
        let after = Date()

        #expect(vm.lastPanelShownAt >= before)
        #expect(vm.lastPanelShownAt <= after)
    }

    @Test("Selection clamps to last row when prior row vanishes mid-array")
    @MainActor
    func selectionClampsWhenRowVanishesInRange() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/c", pid: 3333)
        Thread.sleep(forTimeInterval: 0.01)
        try db.startSession(tool: .claude, directory: "/tmp/b", pid: 2222)
        Thread.sleep(forTimeInterval: 0.01)
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1111)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.selectedIndex == 0)  // A at top
        let aId = vm.selectedSession?.id

        // End A. orderedRows shrinks from [A, B, C] to [B, C].
        try db.endSession(pid: 1111, tool: .claude)
        vm.refresh()

        // A is gone; selectedIndex 0 is still in [0, 2), so the clamp is a
        // no-op and the highlight slides to whatever is at index 0 (B).
        // This pins down the documented behavior.
        #expect(vm.selectedIndex == 0)
        #expect(vm.selectedSession?.id != aId)
        #expect(vm.selectedSession?.pid == 2222)
    }

    @Test("Selection clamps to the last available row when prior row vanishes out of range")
    @MainActor
    func selectionClampsWhenRowVanishesOutOfRange() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/b", pid: 2222)
        Thread.sleep(forTimeInterval: 0.01)
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1111)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        vm.moveSelectionDown()
        #expect(vm.selectedIndex == 1)  // B selected

        // End B. orderedRows shrinks from [A, B] to [A]; selectedIndex 1 is
        // now beyond the new bounds. The clamp brings it to 0 so the
        // highlight lands on A, the last available row.
        try db.endSession(pid: 2222, tool: .claude)
        vm.refresh()

        #expect(vm.selectedIndex == 0)
        #expect(vm.selectedSession?.pid == 1111)
    }

    // MARK: - Latest Assistant Integration Tests
    //
    // Sibling of the away-summary block above: pin the end-to-end glue
    // from `SessionListViewModel.refresh()` through
    // `cachedLatestAssistant(for:)` / `TranscriptLatestAssistantScanner`
    // into the published `latestAssistantById` map. Scanner-unit
    // coverage lives in `TranscriptLatestAssistantScannerTests`; these
    // exercise the cache + prune + non-Claude-guard seams so a refresh()
    // refactor can't silently regress the "live mid-response recap" UX.
    //
    // Fixture pattern mirrors the away-summary tests above byte-for-byte:
    // JSONL written to a `NSTemporaryDirectory()` temp file, path
    // plumbed via `db.updateSession(..., transcriptPath:)`. Fixture
    // bodies are inlined per-test for the same reasons.

    @Test("latestAssistantById populated from Claude transcript")
    @MainActor
    func latestAssistantById_publishedAfterRefresh() throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        let content = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello world"}]},"timestamp":"2026-05-25T01:00:00.000Z","sessionId":"abc"}
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pid: Int = 9101
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/x", pid: pid)
        try db.updateSession(pid: pid, tool: .claude, transcriptPath: path)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.latestAssistantById[session.id] == "Hello world")
    }

    @Test("latestAssistantById is stable across refreshes when transcript is unchanged")
    @MainActor
    func latestAssistantById_cacheReusedOnUnchangedMtime() throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        let content = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Cached value"}]},"timestamp":"2026-05-25T01:00:00.000Z","sessionId":"abc"}
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pid: Int = 9102
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/x", pid: pid)
        try db.updateSession(pid: pid, tool: .claude, transcriptPath: path)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        let firstMtime = (try FileManager.default.attributesOfItem(atPath: path))[.modificationDate] as? Date
        #expect(vm.latestAssistantById[session.id] == "Cached value")

        vm.refresh()
        let secondMtime = (try FileManager.default.attributesOfItem(atPath: path))[.modificationDate] as? Date
        // mtime didn't advance between refreshes (no write happened), so the
        // cache key matched on the second refresh and the published value
        // remained stable. Companion invalidation test below covers the
        // re-scan path when mtime does advance.
        #expect(firstMtime == secondMtime)
        #expect(vm.latestAssistantById[session.id] == "Cached value")
    }

    @Test("latestAssistantById re-scans after the transcript file mtime advances")
    @MainActor
    func latestAssistantById_cacheInvalidatedOnMtimeChange() throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let firstContent = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"First text"}]},"timestamp":"2026-05-25T01:00:00.000Z","sessionId":"abc"}
        """
        try firstContent.write(toFile: path, atomically: true, encoding: .utf8)

        let pid: Int = 9103
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/x", pid: pid)
        try db.updateSession(pid: pid, tool: .claude, transcriptPath: path)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.latestAssistantById[session.id] == "First text")

        // Rewrite with new assistant text and explicitly bump the
        // mtime to dodge macOS's 1-second mtime granularity (mirrors
        // the away-summary rewrite test above).
        let secondContent = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Second text"}]},"timestamp":"2026-05-25T01:00:30.000Z","sessionId":"abc"}
        """
        try secondContent.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: path
        )

        vm.refresh()
        #expect(vm.latestAssistantById[session.id] == "Second text")
    }

    @Test("latestAssistantById drops entries for sessions that leave the live list")
    @MainActor
    func latestAssistantById_prunedWhenSessionRemoved() throws {
        let dir = NSTemporaryDirectory()
        let pathA = (dir as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        let pathB = (dir as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        let contentA = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Alpha text"}]},"timestamp":"2026-05-25T01:00:00.000Z","sessionId":"a"}
        """
        let contentB = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Beta text"}]},"timestamp":"2026-05-25T01:00:00.000Z","sessionId":"b"}
        """
        try contentA.write(toFile: pathA, atomically: true, encoding: .utf8)
        try contentB.write(toFile: pathB, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: pathA)
            try? FileManager.default.removeItem(atPath: pathB)
        }

        let pidA: Int = 9104
        let pidB: Int = 9105
        let db = try SeshctlDatabase.temporary()
        let sessionA = try db.startSession(tool: .claude, directory: "/tmp/a", pid: pidA)
        try db.updateSession(pid: pidA, tool: .claude, transcriptPath: pathA)
        let sessionB = try db.startSession(tool: .claude, directory: "/tmp/b", pid: pidB)
        try db.updateSession(pid: pidB, tool: .claude, transcriptPath: pathB)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        #expect(vm.latestAssistantById[sessionA.id] == "Alpha text")
        #expect(vm.latestAssistantById[sessionB.id] == "Beta text")

        // End session B then immediately GC it out of the DB so it
        // drops out of `listSessions`. The next refresh should rebuild
        // `latestAssistantById` without B's entry and prune the cache
        // entry for B's transcript path.
        try db.endSession(pid: pidB, tool: .claude)
        _ = try db.gc(olderThan: -1)

        vm.refresh()
        #expect(vm.latestAssistantById[sessionA.id] == "Alpha text")
        #expect(vm.latestAssistantById[sessionB.id] == nil)
    }

    @Test("latestAssistantById empty for non-Claude tool")
    @MainActor
    func latestAssistantById_skippedForNonClaudeTools() throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        // Valid Claude-shaped assistant turn — proves the entry is
        // omitted because of the `.claude`-only guard inside
        // `cachedLatestAssistant`, not because the scanner couldn't
        // parse the line.
        let content = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello world"}]},"timestamp":"2026-05-25T01:00:00.000Z","sessionId":"abc"}
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pid: Int = 9106
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .codex, directory: "/tmp/x", pid: pid)
        try db.updateSession(pid: pid, tool: .codex, transcriptPath: path)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        #expect(vm.latestAssistantById[session.id] == nil)
    }
}
