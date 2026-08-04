import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

/// Row deletion, for sessions whose terminal was closed hard: the end hook
/// never fires, so the row lingers with no process left for `x` to signal.
@Suite("SessionListViewModel — delete flow")
struct SessionDeleteFlowTests {

    @Test("requestDelete arms the confirm for the selected row")
    @MainActor
    func requestDeleteArmsConfirm() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/del", pid: 4321)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestDelete()
        #expect(vm.pendingDeleteSessionId == session.id)
        // Nothing is removed until confirmed.
        #expect(vm.sessions.count == 1)
    }

    @Test("Deletes the ghost left by a session with no pid")
    @MainActor
    func deletesPidlessGhost() throws {
        // The real shape of the bug. `reapStaleSessions` only demotes a row
        // when `if let pid = session.pid, !isProcessAlive(pid)` — a session
        // with no pid fails the binding and is never reaped, so it stays
        // active-looking forever with no process for `x` to signal.
        let db = try SeshctlDatabase.temporary()
        // The conversation-id overload is the one that inserts a nil pid —
        // the shape Cursor-style sessions get, since their hook subprocess pid
        // is unstable across events.
        try db.startSession(conversationId: "ghost-1", tool: .claude, directory: "/tmp/ghost")

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        try db.reapStaleSessions()
        vm.refresh()
        // Survived the reaper, still shown as active.
        #expect(vm.sessions.count == 1)
        #expect(vm.sessions[0].isActive)

        vm.requestDelete()
        #expect(vm.pendingDeleteSessionId != nil)
        vm.confirmDelete()

        #expect(vm.sessions.isEmpty)
        #expect(vm.pendingDeleteSessionId == nil)
    }

    @Test("Deletes an already-ended row reached through search")
    @MainActor
    func deletesEndedRowViaSearch() throws {
        // Inactive rows are excluded from `orderedRows` in the default list —
        // they only rejoin while `isSearching`. So an ended row is deletable,
        // but only from the search view, which is where it's visible.
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/del", pid: 4321)
        try db.endSession(pid: 4321, tool: .claude)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        // Not selectable from the default list.
        vm.requestDelete()
        #expect(vm.pendingDeleteSessionId == nil)

        vm.enterSearch()
        vm.refresh()
        vm.requestDelete()
        #expect(vm.pendingDeleteSessionId != nil)
        vm.confirmDelete()
        #expect(vm.sessions.isEmpty)
    }

    @Test("Deletes an active session too")
    @MainActor
    func deletesActiveSession() throws {
        // Unlike kill there's no isActive/pid requirement — a row reporting
        // itself active is exactly the ghost the user wants gone.
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/del", pid: 4321)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestDelete()
        vm.confirmDelete()
        #expect(vm.sessions.isEmpty)
    }

    @Test("cancelDelete leaves the row alone")
    @MainActor
    func cancelKeepsRow() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/del", pid: 4321)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestDelete()
        vm.cancelDelete()
        #expect(vm.pendingDeleteSessionId == nil)

        vm.refresh()
        #expect(vm.sessions.count == 1)
    }

    @Test("confirmDelete without a pending row is a no-op")
    @MainActor
    func confirmWithoutPendingIsNoop() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/del", pid: 4321)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.confirmDelete()
        vm.refresh()
        #expect(vm.sessions.count == 1)
    }

    @Test("Delete and kill arm independent confirmations")
    @MainActor
    func deleteAndKillAreIndependent() throws {
        // Separate pending ids so the two prompts can't be confused — one
        // signals a live process, the other erases a row.
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/del", pid: 4321)

        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()

        vm.requestKill()
        #expect(vm.pendingKillSessionId != nil)
        #expect(vm.pendingDeleteSessionId == nil)

        vm.cancelKill()
        vm.requestDelete()
        #expect(vm.pendingDeleteSessionId != nil)
        #expect(vm.pendingKillSessionId == nil)
    }

    @Test("Database.deleteSession reports whether a row was removed")
    func databaseReportsRemoval() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/del", pid: 4321)

        #expect(try db.deleteSession(id: session.id) == true)
        // Second delete finds nothing — guards double-press and races with gc.
        #expect(try db.deleteSession(id: session.id) == false)
        #expect(try db.listSessions(limit: 10).isEmpty)
    }
}
