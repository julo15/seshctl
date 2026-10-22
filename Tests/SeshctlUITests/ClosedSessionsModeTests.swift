import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

/// The `c` view: closed sessions only, one per conversation, Enter reopens.
@Suite("Closed sessions mode")
struct ClosedSessionsModeTests {
    @MainActor
    private func makeViewModel(_ db: SeshctlDatabase) -> SessionListViewModel {
        let defaults = UserDefaults(suiteName: "closed-mode-\(UUID().uuidString)")!
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()
        return vm
    }

    @MainActor
    private func listedIds(_ vm: SessionListViewModel) -> [String] {
        vm.orderedRows.compactMap { row in
            if case .local(let session) = row { return session.id }
            return nil
        }
    }

    /// A live session plus a closed one, each with a conversation id.
    private func makeDatabase() throws -> (SeshctlDatabase, live: Session, closed: Session) {
        let db = try SeshctlDatabase.temporary()
        let live = try db.startSession(tool: .claude, directory: "/tmp/live", pid: 111, conversationId: "conv-live")
        let closed = try db.startSession(tool: .claude, directory: "/tmp/closed", pid: 222, conversationId: "conv-closed")
        try db.endSession(pid: 222, tool: .claude)
        return (db, live, closed)
    }

    @Test("c swaps the live list for closed sessions, and back")
    @MainActor
    func toggleSwapsLists() throws {
        let (db, live, closed) = try makeDatabase()
        let vm = makeViewModel(db)
        #expect(listedIds(vm) == [live.id])

        vm.toggleRecentsMode()
        #expect(vm.isRecentsMode)
        #expect(listedIds(vm) == [closed.id])
        #expect(vm.selectedSession?.id == closed.id, "Enter should land on the first closed row")

        vm.toggleRecentsMode()
        #expect(!vm.isRecentsMode)
        #expect(listedIds(vm) == [live.id])
    }

    @Test("A conversation resumed several times shows once")
    @MainActor
    func dedupesPerConversation() throws {
        let db = try SeshctlDatabase.temporary()
        for pid in [1, 2, 3] {
            try db.startSession(tool: .claude, directory: "/tmp/a", pid: pid, conversationId: "conv-1")
            try db.endSession(pid: pid, tool: .claude)
        }
        let vm = makeViewModel(db)

        vm.enterRecentsMode()

        #expect(listedIds(vm).count == 1)
    }

    @Test("Rows with nothing to resume are left out")
    @MainActor
    func dropsRowsWithoutConversationId() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/anon", pid: 1)
        try db.endSession(pid: 1, tool: .claude)
        let vm = makeViewModel(db)

        vm.enterRecentsMode()

        #expect(listedIds(vm).isEmpty)
        #expect(vm.emptyState == .noClosedSessions)
    }

    @Test("/ narrows the closed list with the word rule")
    @MainActor
    func searchNarrowsClosedRows() throws {
        let db = try SeshctlDatabase.temporary()
        let hit = try db.startSession(tool: .claude, directory: "/tmp/seshctl", pid: 1, conversationId: "c1")
        try db.updateSession(pid: 1, tool: .claude, ask: "dedupe rows")
        try db.endSession(pid: 1, tool: .claude)
        try db.startSession(tool: .claude, directory: "/tmp/elmozi", pid: 2, conversationId: "c2")
        try db.endSession(pid: 2, tool: .claude)
        let vm = makeViewModel(db)

        vm.enterRecentsMode()
        vm.enterSearch()
        for character in "sesh dedupe" { vm.appendSearchCharacter(String(character)) }

        #expect(listedIds(vm) == [hit.id], "Search inside c stays on closed rows")
        #expect(vm.isRecentsMode)
    }

    @Test("Tree mode is overridden while in c, without losing the saved setting")
    @MainActor
    func treeModeIsSuspendedNotChanged() throws {
        let (db, _, closed) = try makeDatabase()
        let vm = makeViewModel(db)
        vm.toggleViewMode()
        #expect(vm.isTreeMode)

        vm.enterRecentsMode()
        #expect(listedIds(vm) == [closed.id])
        #expect(vm.isTreeMode, "the persisted tree preference must survive the c view")

        vm.exitRecentsMode()
        #expect(vm.isTreeMode)
    }

    @Test("Entering c cancels a pending kill")
    @MainActor
    func enteringClearsPendingConfirmations() throws {
        let (db, _, _) = try makeDatabase()
        let vm = makeViewModel(db)
        vm.requestKill()
        #expect(vm.pendingKillSessionId != nil)

        vm.enterRecentsMode()

        #expect(vm.pendingKillSessionId == nil)
    }

    @Test("Closed rows refresh while c is open")
    @MainActor
    func refreshReloadsClosedRows() throws {
        let (db, live, closed) = try makeDatabase()
        let vm = makeViewModel(db)
        vm.enterRecentsMode()

        try db.endSession(pid: 111, tool: .claude)
        vm.refresh()

        #expect(Set(listedIds(vm)) == [live.id, closed.id])
    }

    // MARK: - Esc / q

    @Test("Esc backs out of c before the panel closes")
    @MainActor
    func backOutLeavesCFirst() throws {
        let (db, _, _) = try makeDatabase()
        let vm = makeViewModel(db)
        vm.enterRecentsMode()

        #expect(vm.backOutOfRecentsMode(), "first press leaves c")
        #expect(!vm.isRecentsMode)
        #expect(!vm.backOutOfRecentsMode(), "second press has nothing to back out of, so the panel closes")
    }

    // MARK: - Cloud rows

    private func remote(id: String, connected: Bool) -> RemoteClaudeCodeSession {
        RemoteClaudeCodeSession(
            id: id,
            title: "cloud \(id)",
            model: "claude-opus-4-6[1m]",
            repoUrl: nil,
            branches: [],
            status: "active",
            workerStatus: "idle",
            connectionStatus: connected ? "connected" : "disconnected",
            lastEventAt: Date(),
            createdAt: Date(),
            unread: false
        )
    }

    @MainActor
    private func listedRemoteIds(_ vm: SessionListViewModel) -> [String] {
        vm.orderedRows.compactMap { row in
            if case .remote(let remote) = row { return remote.id }
            return nil
        }
    }

    @Test("c lists disconnected cloud sessions but never connected ones")
    @MainActor
    func cloudRowsOnlyWhenDisconnected() throws {
        let (db, _, _) = try makeDatabase()
        try db.upsertRemoteClaudeCodeSessions([remote(id: "live", connected: true), remote(id: "gone", connected: false)])
        let vm = makeViewModel(db)

        vm.enterRecentsMode()

        #expect(listedRemoteIds(vm) == ["gone"], "a connected cloud session is live, not closed")
    }

    @Test("The source filter applies inside c")
    @MainActor
    func sourceFilterAppliesInC() throws {
        let (db, _, closed) = try makeDatabase()
        try db.upsertRemoteClaudeCodeSessions([remote(id: "gone", connected: false)])
        let vm = makeViewModel(db)
        vm.enterRecentsMode()

        vm.sourceFilter = .localOnly
        #expect(listedIds(vm) == [closed.id])
        #expect(listedRemoteIds(vm).isEmpty)

        vm.sourceFilter = .remoteOnly
        #expect(listedIds(vm).isEmpty)
        #expect(listedRemoteIds(vm) == ["gone"])
    }

    // MARK: - Ordering, titles, mode isolation

    @Test("Closed rows are newest first even with the order frozen")
    @MainActor
    func orderIsRecencyWhileFrozen() throws {
        let db = try SeshctlDatabase.temporary()
        var ids: [String] = []
        for pid in 1...3 {
            let s = try db.startSession(tool: .claude, directory: "/tmp/\(pid)", pid: pid, conversationId: "c\(pid)")
            try db.endSession(pid: pid, tool: .claude)
            try db.dbPool.write {
                try $0.execute(sql: "UPDATE sessions SET updated_at = ? WHERE id = ?",
                               arguments: [Date(timeIntervalSince1970: Double(1000 + pid)), s.id])
            }
            ids.append(s.id)
        }
        let vm = makeViewModel(db)
        vm.setOrderFrozen(true)

        vm.enterRecentsMode()

        #expect(listedIds(vm) == ids.reversed())
    }

    @Test("Closed rows older than the newest 50 still get titles in c")
    @MainActor
    func titlesReachPastTheNewest50() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        try #"{"type":"ai-title","aiTitle":"Old but titled"}"#.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try SeshctlDatabase.temporary()
        let old = try db.startSession(tool: .claude, directory: "/tmp/old", pid: 9000, conversationId: "old")
        try db.updateSession(pid: 9000, tool: .claude, transcriptPath: path)
        try db.endSession(pid: 9000, tool: .claude)
        try db.dbPool.write {
            try $0.execute(sql: "UPDATE sessions SET updated_at = ? WHERE id = ?",
                           arguments: [Date(timeIntervalSince1970: 1), old.id])
        }
        for pid in 1...55 {
            try db.startSession(tool: .claude, directory: "/tmp/\(pid)", pid: pid, conversationId: "n\(pid)")
        }
        let vm = makeViewModel(db)
        #expect(!vm.sessions.contains { $0.id == old.id }, "precondition: outside the newest 50")

        vm.enterRecentsMode()

        #expect(vm.titlesById[old.id] == "Old but titled")
    }

    @Test("v and the group-jump keys do nothing in c")
    @MainActor
    func treeKeysAreInertInC() throws {
        let (db, _, closed) = try makeDatabase()
        let vm = makeViewModel(db)
        vm.toggleViewMode()
        #expect(vm.isTreeMode, "precondition: tree mode saved on")
        vm.enterRecentsMode()

        vm.toggleViewMode()
        #expect(vm.isTreeMode, "v would flip the saved preference with nothing visible")

        vm.jumpToNextGroup()
        #expect(vm.selectedSession?.id == closed.id, "tree group jumps must not move the c selection")
    }
}
