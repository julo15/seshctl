import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

@Suite("Title suggestions")
struct TitleSuggestionTests {
    @MainActor
    private func makeViewModel(_ db: SeshctlDatabase, titles: [String] = ["Alpha", "Beta", "Gamma"]) -> SessionListViewModel {
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: UserDefaults(suiteName: "titles-\(UUID().uuidString)")!)
        vm.titleSuggestionGenerator = { _, _ in titles }
        vm.refresh()
        return vm
    }

    /// The generator runs in a detached task; wait for its result to land.
    @MainActor
    private func waitForSuggestions(_ vm: SessionListViewModel, id: String) async {
        for _ in 0..<200 where vm.titleSuggestionsById[id] == .loading {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("t shows Titling…, then three candidates")
    @MainActor
    func requestShowsCandidates() async throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        let vm = makeViewModel(db)

        vm.requestTitleSuggestions()
        #expect(vm.titleSuggestionsById[session.id] == .loading)
        await waitForSuggestions(vm, id: session.id)

        #expect(vm.titleSuggestionsById[session.id] == .ready(["Alpha", "Beta", "Gamma"]))
    }

    @Test("Picking saves the title for the conversation, across resumes and restarts")
    @MainActor
    func pickPersistsPerConversation() async throws {
        let db = try SeshctlDatabase.temporary()
        let first = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        let vm = makeViewModel(db)
        vm.requestTitleSuggestions()
        await waitForSuggestions(vm, id: first.id)

        #expect(vm.pickTitleSuggestion(1))
        #expect(vm.titlesById[first.id] == "Beta")
        #expect(vm.titleSuggestionsById[first.id] == nil)

        // Resume: a new row for the same conversation, in a fresh app launch.
        try db.endSession(pid: 1, tool: .claude)
        let resumed = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 2, conversationId: "conv-a")
        let relaunched = makeViewModel(db)
        #expect(relaunched.titlesById[resumed.id] == "Beta")
    }

    @Test("A picked title also names Codex rows, which Claude never titles")
    @MainActor
    func codexRowsGetTitles() async throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .codex, directory: "/tmp/x", pid: 1, conversationId: "codex-1")
        let vm = makeViewModel(db)
        vm.requestTitleSuggestions()
        await waitForSuggestions(vm, id: session.id)

        vm.pickTitleSuggestion(0)

        #expect(vm.titlesById[session.id] == "Alpha")
    }

    @Test("Esc discards the suggestions and keeps the current title")
    @MainActor
    func dismissKeepsTitle() async throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        let vm = makeViewModel(db)
        vm.requestTitleSuggestions()
        await waitForSuggestions(vm, id: session.id)

        #expect(vm.dismissTitleSuggestions())
        #expect(vm.titleSuggestionsById[session.id] == nil)
        #expect(vm.titlesById[session.id] == nil)
        #expect(!vm.dismissTitleSuggestions(), "nothing left, so Esc moves on to its other jobs")
    }

    @Test("1–3 only act on the selected row's suggestions")
    @MainActor
    func pickIgnoresOtherRows() async throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        try db.startSession(tool: .claude, directory: "/tmp/b", pid: 2, conversationId: "conv-b")
        let vm = makeViewModel(db)
        let top = try #require(vm.selectedSession)
        vm.requestTitleSuggestions()
        await waitForSuggestions(vm, id: top.id)

        vm.moveSelectionDown()
        #expect(!vm.pickTitleSuggestion(0))
        #expect(vm.titleSuggestionsById[top.id] != nil, "the other row's suggestions wait for it")
        #expect(!vm.pickTitleSuggestion(5), "out of range")
    }

    @Test("No titles back shows a failure note")
    @MainActor
    func failureState() async throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        let vm = makeViewModel(db, titles: [])

        vm.requestTitleSuggestions()
        await waitForSuggestions(vm, id: session.id)

        #expect(vm.titleSuggestionsById[session.id] == .failed)
        #expect(!vm.pickTitleSuggestion(0))
    }

    @Test("Rows that can't be retitled ignore t")
    @MainActor
    func untitleableRows() throws {
        let db = try SeshctlDatabase.temporary()
        let gemini = try db.startSession(tool: .gemini, directory: "/tmp/g", pid: 1, conversationId: "g")
        let vm = makeViewModel(db)
        vm.requestTitleSuggestions()
        #expect(vm.titleSuggestionsById[gemini.id] == nil)

        let db2 = try SeshctlDatabase.temporary()
        let anonymous = try db2.startSession(tool: .claude, directory: "/tmp/a", pid: 1)
        let vm2 = makeViewModel(db2)
        vm2.requestTitleSuggestions()
        #expect(vm2.titleSuggestionsById[anonymous.id] == nil, "no conversation id to store the title under")
    }
}
