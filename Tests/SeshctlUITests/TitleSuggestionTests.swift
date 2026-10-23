import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

@Suite("Title suggestions")
struct TitleSuggestionTests {
    @MainActor
    private func makeViewModel(_ db: SeshctlDatabase, title: String? = "Alpha") -> SessionListViewModel {
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: UserDefaults(suiteName: "titles-\(UUID().uuidString)")!)
        vm.titleSuggestionGenerator = { _ in title.map { .success($0) } ?? .failure(.runFailed) }
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

    @Test("t shows Titling…, then the suggested title")
    @MainActor
    func requestShowsCandidates() async throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        let vm = makeViewModel(db)

        vm.requestTitleSuggestion()
        #expect(vm.titleSuggestionsById[session.id] == .loading)
        await waitForSuggestions(vm, id: session.id)

        #expect(vm.titleSuggestionsById[session.id] == .ready("Alpha"))
    }

    @Test("y saves the title for the conversation, across resumes and restarts")
    @MainActor
    func pickPersistsPerConversation() async throws {
        let db = try SeshctlDatabase.temporary()
        let first = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        let vm = makeViewModel(db)
        vm.requestTitleSuggestion()
        await waitForSuggestions(vm, id: first.id)

        #expect(vm.acceptTitleSuggestion())
        #expect(vm.titlesById[first.id] == "Alpha")
        #expect(vm.titleSuggestionsById[first.id] == nil)

        // Resume: a new row for the same conversation, in a fresh app launch.
        try db.endSession(pid: 1, tool: .claude)
        let resumed = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 2, conversationId: "conv-a")
        let relaunched = makeViewModel(db)
        #expect(relaunched.titlesById[resumed.id] == "Alpha")
    }

    @Test("An accepted title also names Codex rows, which Claude never titles")
    @MainActor
    func codexRowsGetTitles() async throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .codex, directory: "/tmp/x", pid: 1, conversationId: "codex-1")
        let vm = makeViewModel(db)
        vm.requestTitleSuggestion()
        await waitForSuggestions(vm, id: session.id)

        vm.acceptTitleSuggestion()

        #expect(vm.titlesById[session.id] == "Alpha")
    }

    @Test("n or Esc declines the suggestion and keeps the current title")
    @MainActor
    func dismissKeepsTitle() async throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        let vm = makeViewModel(db)
        vm.requestTitleSuggestion()
        await waitForSuggestions(vm, id: session.id)

        #expect(vm.dismissTitleSuggestion())
        #expect(vm.titleSuggestionsById[session.id] == nil)
        #expect(vm.titlesById[session.id] == nil)
        #expect(!vm.dismissTitleSuggestion(), "nothing left, so Esc moves on to its other jobs")
    }

    @Test("y only acts on the selected row's suggestion")
    @MainActor
    func pickIgnoresOtherRows() async throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        try db.startSession(tool: .claude, directory: "/tmp/b", pid: 2, conversationId: "conv-b")
        let vm = makeViewModel(db)
        let top = try #require(vm.selectedSession)
        vm.requestTitleSuggestion()
        await waitForSuggestions(vm, id: top.id)

        vm.moveSelectionDown()
        #expect(!vm.acceptTitleSuggestion())
        #expect(vm.titleSuggestionsById[top.id] != nil, "the other row's suggestion waits for it")
    }

    @Test("No title back shows a failure note")
    @MainActor
    func failureState() async throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        let vm = makeViewModel(db, title: nil)

        vm.requestTitleSuggestion()
        await waitForSuggestions(vm, id: session.id)

        #expect(vm.titleSuggestionsById[session.id] == .failed(.runFailed))
        #expect(!vm.acceptTitleSuggestion())
    }

    @Test("Rows that can't be retitled ignore t")
    @MainActor
    func untitleableRows() throws {
        let db = try SeshctlDatabase.temporary()
        let gemini = try db.startSession(tool: .gemini, directory: "/tmp/g", pid: 1, conversationId: "g")
        let vm = makeViewModel(db)
        vm.requestTitleSuggestion()
        #expect(vm.titleSuggestionsById[gemini.id] == nil)

        let db2 = try SeshctlDatabase.temporary()
        let anonymous = try db2.startSession(tool: .claude, directory: "/tmp/a", pid: 1)
        let vm2 = makeViewModel(db2)
        vm2.requestTitleSuggestion()
        #expect(vm2.titleSuggestionsById[anonymous.id] == nil, "no conversation id to store the title under")
    }

    @Test("t, n, t: the first run's late result doesn't replace the second's")
    @MainActor
    func staleResultIsDropped() async throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        let vm = makeViewModel(db)
        let firstRelease = DispatchSemaphore(value: 0)
        let calls = Counter()
        vm.titleSuggestionGenerator = { _ in
            if calls.next() == 1 {
                firstRelease.wait()
                return .success("Stale")
            }
            return .success("Fresh")
        }

        vm.requestTitleSuggestion()
        #expect(vm.dismissTitleSuggestion())
        vm.requestTitleSuggestion()
        await waitForSuggestions(vm, id: session.id)
        #expect(vm.titleSuggestionsById[session.id] == .ready("Fresh"))

        firstRelease.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(vm.titleSuggestionsById[session.id] == .ready("Fresh"))
    }

    @Test("A declined request's late result doesn't come back")
    @MainActor
    func declinedResultIsDropped() async throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        let vm = makeViewModel(db)
        let release = DispatchSemaphore(value: 0)
        vm.titleSuggestionGenerator = { _ in
            release.wait()
            return .success("Late")
        }

        vm.requestTitleSuggestion()
        #expect(vm.dismissTitleSuggestion())
        release.signal()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(vm.titleSuggestionsById[session.id] == nil)
    }

    @Test("t while a request is running doesn't start another")
    @MainActor
    func repeatWhileLoadingIsIgnored() async throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        let vm = makeViewModel(db)
        let calls = Counter()
        vm.titleSuggestionGenerator = { _ in .success("Run \(calls.next())") }

        vm.requestTitleSuggestion()
        vm.requestTitleSuggestion()
        await waitForSuggestions(vm, id: session.id)
        #expect(vm.titleSuggestionsById[session.id] == .ready("Run 1"))

        vm.requestTitleSuggestion()
        await waitForSuggestions(vm, id: session.id)
        #expect(vm.titleSuggestionsById[session.id] == .ready("Run 2"), "t on a ready suggestion asks again")
    }

    @Test("An accepted title beats Claude's own, in the closed-sessions view too")
    @MainActor
    func acceptedTitleBeatsScannedTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("titles-\(UUID().uuidString)")
        let transcript = root.appendingPathComponent("conv-a.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"type":"ai-title","aiTitle":"First task"}"#.write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a", transcriptPath: transcript.path)
        let vm = makeViewModel(db)
        #expect(vm.titlesById[session.id] == "First task")

        vm.requestTitleSuggestion()
        await waitForSuggestions(vm, id: session.id)
        vm.acceptTitleSuggestion()
        #expect(vm.titlesById[session.id] == "Alpha")

        try db.endSession(pid: 1, tool: .claude)
        vm.enterRecentsMode()
        #expect(vm.titlesById[session.id] == "Alpha")
    }

    @Test("A failed save shows the error and keeps the suggestion")
    @MainActor
    func acceptSaveFailure() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("titles-\(UUID().uuidString).sqlite").path
        let db = try SeshctlDatabase(path: path)
        let session = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-a")
        let vm = makeViewModel(db)
        vm.requestTitleSuggestion()
        await waitForSuggestions(vm, id: session.id)

        let drop = Process()
        drop.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        drop.arguments = [path, "DROP TABLE conversation_titles"]
        try drop.run()
        drop.waitUntilExit()

        #expect(vm.acceptTitleSuggestion())
        #expect(vm.error != nil)
        #expect(vm.titleSuggestionsById[session.id] == .ready("Alpha"))
    }

    @Test("The default generator names what's missing before running anything")
    func defaultGeneratorFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("titles-\(UUID().uuidString)")
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "conv-missing")
        let cli = URL(fileURLWithPath: "/bin/claude")

        let noCLI = SessionListViewModel.suggestTitle(for: session, projectsRoot: root, resolveCLI: { nil }) { _, _ in .success("x") }
        #expect(noCLI == .failure(.cliNotFound))

        let noTranscript = SessionListViewModel.suggestTitle(for: session, projectsRoot: root, resolveCLI: { cli }) { _, _ in .success("x") }
        #expect(noTranscript == .failure(.nothingToTitle))
    }

    @Test("The default generator reads a Codex rollout from its stored path")
    func defaultGeneratorCodex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("titles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent("rollout.jsonl")
        try #"{"timestamp":"2026-01-01T00:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the codex badge"}]}}"#
            .write(to: rollout, atomically: true, encoding: .utf8)

        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .codex, directory: "/tmp/x", pid: 1, conversationId: "codex-1", transcriptPath: rollout.path)
        var prompt: String?
        let result = SessionListViewModel.suggestTitle(for: session, projectsRoot: root, resolveCLI: { URL(fileURLWithPath: "/bin/claude") }) { p, _ in
            prompt = p
            return .success("Codex badge")
        }

        #expect(result == .success("Codex badge"))
        #expect(prompt?.contains("fix the codex badge") == true)
    }
}

/// A thread-safe call counter for generators, which run off the main actor.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
