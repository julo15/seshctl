import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

@Suite("Model pill")
struct ModelPillTests {
    private func writeTranscript(_ lines: [String]) throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func assistant(_ model: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","model":"\#(model)","content":[{"type":"text","text":"hi"}]}}"#
    }

    @Test("The usual model per agent is the most common one, ties broken by name")
    func usualModels() {
        let usual = SessionListViewModel.usualModels(
            local: [(.claude, "Opus 5.5"), (.claude, "Fable 5.1"), (.codex, "GPT-5.5")],
            remote: ["claude-opus-5-5"]
        )
        // Locally it's a 1–1 tie that would go to Fable; the cloud row breaks it.
        #expect(usual == [.claude: "Opus 5.5", .codex: "GPT-5.5"])

        let tied = SessionListViewModel.usualModels(local: [(.claude, "Opus 5.5"), (.claude, "Fable 5.1")], remote: [])
        #expect(tied == [.claude: "Fable 5.1"], "alphabetical tie-break keeps the highlight steady")
    }

    @Test("Rows get a pill from their transcript; only the odd model out is highlighted")
    @MainActor
    func pillsFromTranscripts() throws {
        let opus = try writeTranscript([assistant("claude-opus-5-5")])
        let fable = try writeTranscript([assistant("claude-fable-5-1")])
        let codex = try writeTranscript([#"{"type":"turn_context","payload":{"model":"gpt-5.6-terra"}}"#])
        defer { [opus, fable, codex].forEach { try? FileManager.default.removeItem(atPath: $0) } }

        let db = try SeshctlDatabase.temporary()
        let a = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1, conversationId: "a")
        try db.updateSession(pid: 1, tool: .claude, transcriptPath: opus)
        let b = try db.startSession(tool: .claude, directory: "/tmp/b", pid: 2, conversationId: "b")
        try db.updateSession(pid: 2, tool: .claude, transcriptPath: opus)
        let c = try db.startSession(tool: .claude, directory: "/tmp/c", pid: 3, conversationId: "c")
        try db.updateSession(pid: 3, tool: .claude, transcriptPath: fable)
        let x = try db.startSession(tool: .codex, directory: "/tmp/x", pid: 4, conversationId: "x")
        try db.updateSession(pid: 4, tool: .codex, transcriptPath: codex)
        let none = try db.startSession(tool: .gemini, directory: "/tmp/g", pid: 5)

        let defaults = UserDefaults(suiteName: "model-pill-\(UUID().uuidString)")!
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: defaults)
        vm.refresh()

        #expect(vm.modelPill(for: a) == ModelPill(name: "Opus 5.5", isUnusual: false))
        #expect(vm.modelPill(for: b) == ModelPill(name: "Opus 5.5", isUnusual: false))
        #expect(vm.modelPill(for: c) == ModelPill(name: "Fable 5.1", isUnusual: true))
        #expect(vm.modelPill(for: x) == ModelPill(name: "GPT-5.6 Terra", isUnusual: false), "a lone Codex row is Codex's usual")
        #expect(vm.modelPill(for: none) == nil, "no transcript, no pill")
    }

    @Test("A cloud row's pill comes from its reported model")
    @MainActor
    func remotePill() throws {
        let db = try SeshctlDatabase.temporary()
        let vm = SessionListViewModel(database: db, enableGC: false, defaults: UserDefaults(suiteName: "model-pill-\(UUID().uuidString)")!)
        let remote = RemoteClaudeCodeSession(
            id: "r1", title: "t", model: "claude-opus-4-6[1m]", repoUrl: nil, branches: [],
            status: "active", workerStatus: "idle", connectionStatus: "connected",
            lastEventAt: Date(), createdAt: Date(), unread: false
        )

        #expect(vm.modelPill(for: remote) == ModelPill(name: "Opus 4.6", isUnusual: false))
    }
}
