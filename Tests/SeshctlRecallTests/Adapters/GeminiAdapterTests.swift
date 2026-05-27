// GeminiAdapterTests — dedupes by (sessionId, messageId). Tests use a temp
// `baseDir` so `~/.gemini/tmp/` is never touched.

import Foundation
import Testing

@testable import SeshctlRecall

private struct GeminiFixture {
    let baseDir: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("seshctl-gemini-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true, attributes: nil
        )
        self.baseDir = base
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: baseDir)
    }

    /// Write `logs.json` and optionally `.project_root` for a session dir.
    func writeSession(
        name: String,
        messages: [[String: Any]],
        projectRoot: String? = nil
    ) throws -> URL {
        let dir = baseDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: nil
        )
        let logsURL = dir.appendingPathComponent("logs.json")
        let data = try JSONSerialization.data(
            withJSONObject: messages,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: logsURL)
        if let projectRoot {
            let rootURL = dir.appendingPathComponent(".project_root")
            try projectRoot.data(using: .utf8)!.write(to: rootURL)
        }
        return dir
    }

    func writeCorruptedSession(name: String) throws {
        let dir = baseDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: nil
        )
        let logsURL = dir.appendingPathComponent("logs.json")
        try "not valid json {{{".data(using: .utf8)!.write(to: logsURL)
    }
}

private func userMsg(
    sessionID: String,
    messageID: Any,
    text: String,
    timestamp: String = "2026-05-25T11:00:00.000Z"
) -> [String: Any] {
    [
        "type": "user",
        "sessionId": sessionID,
        "messageId": messageID,
        "message": text,
        "timestamp": timestamp,
    ]
}

private func nonUserMsg(sessionID: String, messageID: Any) -> [String: Any] {
    [
        "type": "model",
        "sessionId": sessionID,
        "messageId": messageID,
        "message": "assistant reply we ignore",
        "timestamp": "2026-05-25T11:00:01.000Z",
    ]
}

@Suite("GeminiAdapter")
struct GeminiAdapterTests {
    @Test("first-run loads all user messages from every session")
    func firstRunLoadsAll() async throws {
        let fx = try GeminiFixture()
        defer { fx.cleanup() }
        _ = try fx.writeSession(
            name: "sessA",
            messages: [
                userMsg(sessionID: "sessA", messageID: 1, text: "first"),
                userMsg(sessionID: "sessA", messageID: 2, text: "second"),
            ],
            projectRoot: "/Users/julianlo/projA"
        )
        _ = try fx.writeSession(
            name: "sessB",
            messages: [userMsg(sessionID: "sessB", messageID: 1, text: "elsewhere")],
            projectRoot: "/Users/julianlo/projB"
        )

        let adapter = GeminiAdapter(baseDir: fx.baseDir)
        let (entries, cursor) = try await adapter.load(cursor: nil)
        #expect(entries.count == 3)
        let texts = Set(entries.map(\.text))
        #expect(texts == ["first", "second", "elsewhere"])
        #expect(entries.allSatisfy { $0.agent == "gemini" && $0.role == "user" })
        #expect(!cursor.isEmpty)
    }

    @Test("second run dedups via session+message IDs")
    func secondRunDedup() async throws {
        let fx = try GeminiFixture()
        defer { fx.cleanup() }
        _ = try fx.writeSession(
            name: "sessA",
            messages: [userMsg(sessionID: "sessA", messageID: 1, text: "one")]
        )
        let adapter = GeminiAdapter(baseDir: fx.baseDir)
        let (first, cursor) = try await adapter.load(cursor: nil)
        #expect(first.count == 1)
        // Second run on the same file — no new entries.
        let (second, _) = try await adapter.load(cursor: cursor)
        #expect(second.isEmpty)
    }

    @Test("non-user messages are skipped but their key is added to seen")
    func nonUserSkippedButTracked() async throws {
        let fx = try GeminiFixture()
        defer { fx.cleanup() }
        _ = try fx.writeSession(
            name: "sessMix",
            messages: [
                nonUserMsg(sessionID: "sessMix", messageID: 1),
                userMsg(sessionID: "sessMix", messageID: 2, text: "the real one"),
            ]
        )
        let adapter = GeminiAdapter(baseDir: fx.baseDir)
        let (entries, cursor) = try await adapter.load(cursor: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.text == "the real one")
        // Cursor's seen set should include both keys (so the model entry is
        // not re-evaluated next run).
        let decoded = GeminiAdapter.decodeCursor(cursor)
        let keys = Set(decoded.seen.map { $0.joined(separator: "|") })
        #expect(keys.contains("sessMix|1"))
        #expect(keys.contains("sessMix|2"))
    }

    @Test("project is read from sibling .project_root file")
    func projectFromSiblingFile() async throws {
        let fx = try GeminiFixture()
        defer { fx.cleanup() }
        _ = try fx.writeSession(
            name: "sessP",
            messages: [userMsg(sessionID: "sessP", messageID: 1, text: "hi")],
            projectRoot: "/Users/julianlo/with-root"
        )
        let adapter = GeminiAdapter(baseDir: fx.baseDir)
        let (entries, _) = try await adapter.load(cursor: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.project == "/Users/julianlo/with-root")
    }

    @Test("session without .project_root yields empty project")
    func projectEmptyWhenSiblingMissing() async throws {
        let fx = try GeminiFixture()
        defer { fx.cleanup() }
        _ = try fx.writeSession(
            name: "sessQ",
            messages: [userMsg(sessionID: "sessQ", messageID: 1, text: "hi")]
        )
        let adapter = GeminiAdapter(baseDir: fx.baseDir)
        let (entries, _) = try await adapter.load(cursor: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.project == "")
    }

    @Test("malformed logs.json file is skipped, other sessions still load")
    func malformedFileSkipped() async throws {
        let fx = try GeminiFixture()
        defer { fx.cleanup() }
        try fx.writeCorruptedSession(name: "broken")
        _ = try fx.writeSession(
            name: "ok",
            messages: [userMsg(sessionID: "ok", messageID: 1, text: "still here")]
        )
        let adapter = GeminiAdapter(baseDir: fx.baseDir)
        let (entries, _) = try await adapter.load(cursor: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.text == "still here")
    }

    @Test("entries with empty message text are skipped but tracked")
    func emptyTextSkippedButTracked() async throws {
        let fx = try GeminiFixture()
        defer { fx.cleanup() }
        _ = try fx.writeSession(
            name: "sessE",
            messages: [
                userMsg(sessionID: "sessE", messageID: 1, text: ""),
                userMsg(sessionID: "sessE", messageID: 2, text: "   "),
                userMsg(sessionID: "sessE", messageID: 3, text: "kept"),
            ]
        )
        let adapter = GeminiAdapter(baseDir: fx.baseDir)
        let (entries, cursor) = try await adapter.load(cursor: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.text == "kept")
        let decoded = GeminiAdapter.decodeCursor(cursor)
        let keys = Set(decoded.seen.map { $0.joined(separator: "|") })
        #expect(keys.contains("sessE|1"))
        #expect(keys.contains("sessE|2"))
        #expect(keys.contains("sessE|3"))
    }
}
