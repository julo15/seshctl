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
}
