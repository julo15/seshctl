import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

@Suite("SessionListViewModel row clicks")
@MainActor
struct SessionListViewModelClickTests {
    /// Three active sessions, selection on the first row.
    private func makeViewModel() throws -> SessionListViewModel {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1111)
        try db.startSession(tool: .claude, directory: "/tmp/b", pid: 2222)
        try db.startSession(tool: .claude, directory: "/tmp/c", pid: 3333)
        let vm = SessionListViewModel(database: db, enableGC: false)
        vm.refresh()
        vm.selectedIndex = 0
        return vm
    }

    private func historyResult(_ sessionId: String) -> RecallResult {
        RecallResult(
            agent: "claude", role: "user", sessionId: sessionId,
            project: "/tmp/project", timestamp: 1_800_000_000,
            score: 0.9, resumeCmd: "claude --resume \(sessionId)", text: "text for \(sessionId)"
        )
    }

    @Test("Compact: first click selects, a click on the selected row opens")
    func compactSelectThenOpen() throws {
        let vm = try makeViewModel()
        let target = vm.orderedRows[2]

        #expect(vm.clickRow(id: target.id, layout: .compact) == .select)
        #expect(vm.selectedIndex == 2)
        #expect(vm.clickRow(id: target.id, layout: .compact) == .open)
        #expect(vm.selectedRow?.id == target.id)
    }

    @Test("Stacked opens on the first click")
    func stackedOpensImmediately() throws {
        let vm = try makeViewModel()
        let target = vm.orderedRows[1]
        #expect(vm.clickRow(id: target.id, layout: .stacked) == .open)
        #expect(vm.selectedRow?.id == target.id)
    }

    @Test("A click selects the row by id, wherever it now sits")
    func looksUpById() throws {
        let vm = try makeViewModel()
        let target = vm.orderedRows[2]
        // A row the view drew at some other position still resolves to its
        // current index.
        #expect(vm.clickRow(id: target.id, layout: .stacked) == .open)
        #expect(vm.orderedRows[vm.selectedIndex].id == target.id)
    }

    @Test("A click on a row that's gone does nothing")
    func unknownRow() throws {
        let vm = try makeViewModel()
        #expect(vm.clickRow(id: "no-such-row", layout: .stacked) == nil)
        #expect(vm.selectedIndex == 0)
    }

    @Test("A click clears pending kill, fork and mark-all prompts")
    func clearsPendingPrompts() throws {
        let vm = try makeViewModel()
        vm.pendingKillSessionId = "a"
        vm.pendingForkSessionId = "b"
        vm.pendingMarkAllRead = true

        vm.clickRow(id: vm.orderedRows[1].id, layout: .compact)

        #expect(vm.pendingKillSessionId == nil)
        #expect(vm.pendingForkSessionId == nil)
        #expect(vm.pendingMarkAllRead == false)
    }

    @Test("A click while typing a search switches to navigation mode")
    func clickEntersSearchNavigation() throws {
        let vm = try makeViewModel()
        vm.isSearching = true
        vm.isNavigatingSearch = false
        vm.clickRow(id: vm.orderedRows[0].id, layout: .compact)
        #expect(vm.isNavigatingSearch)
    }

    @Test("A click outside search leaves navigation mode alone")
    func clickOutsideSearch() throws {
        let vm = try makeViewModel()
        vm.clickRow(id: vm.orderedRows[0].id, layout: .compact)
        #expect(vm.isNavigatingSearch == false)
    }

    @Test("A second open of the same row inside the repeat window is dropped")
    func repeatOpenSuppressed() throws {
        let vm = try makeViewModel()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        vm.clickClock = { now }
        let id = vm.orderedRows[1].id

        #expect(vm.clickRow(id: id, layout: .stacked) == .open)
        now += SessionListViewModel.repeatOpenWindow / 2
        #expect(vm.clickRow(id: id, layout: .stacked) == .select)
        now += SessionListViewModel.repeatOpenWindow
        #expect(vm.clickRow(id: id, layout: .stacked) == .open)
    }

    @Test("Compact double click on an unselected row selects then opens")
    func compactDoubleClickOpensOnce() throws {
        let vm = try makeViewModel()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        vm.clickClock = { now }
        let id = vm.orderedRows[2].id
        #expect(vm.clickRow(id: id, layout: .compact) == .select)
        #expect(vm.clickRow(id: id, layout: .compact) == .open)
        #expect(vm.clickRow(id: id, layout: .compact) == .select)  // third click: repeat
    }

    @Test("Opening a different row isn't treated as a repeat")
    func differentRowNotRepeat() throws {
        let vm = try makeViewModel()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        vm.clickClock = { now }
        #expect(vm.clickRow(id: vm.orderedRows[1].id, layout: .stacked) == .open)
        #expect(vm.clickRow(id: vm.orderedRows[2].id, layout: .stacked) == .open)
    }

    @Test("History results select first, then open, at the index after the live rows")
    func historyClick() throws {
        let vm = try makeViewModel()
        vm.isSearching = true
        vm.recallResults = [historyResult("conv-1"), historyResult("conv-2")]
        let target = vm.recallResults[1]

        #expect(vm.clickHistoryResult(id: target.id) == .select)
        #expect(vm.selectedIndex == vm.orderedRows.count + 1)
        #expect(vm.selectedRecallResult?.id == target.id)
        #expect(vm.clickHistoryResult(id: target.id) == .open)
    }

    @Test("History clicks do nothing outside search")
    func historyClickOutsideSearch() throws {
        let vm = try makeViewModel()
        vm.recallResults = [historyResult("conv-1")]
        #expect(vm.clickHistoryResult(id: vm.recallResults[0].id) == nil)
        #expect(vm.selectedIndex == 0)
    }
}
