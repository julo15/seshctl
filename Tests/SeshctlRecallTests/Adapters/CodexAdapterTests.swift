// CodexAdapterTests — single-file resumable JSONL with a byte-offset cursor.
// Tests use a temp `history.jsonl` so `~/.codex/` is never touched.

import Foundation
import Testing

@testable import SeshctlRecall

private struct CodexFixture {
    let historyPath: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("seshctl-codex-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true, attributes: nil
        )
        self.historyPath = base.appendingPathComponent("history.jsonl")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: historyPath.deletingLastPathComponent())
    }

    func writeLines(_ lines: [String]) throws {
        let body = lines.joined(separator: "\n") + "\n"
        try body.data(using: .utf8)!.write(to: historyPath)
    }

    func appendLines(_ lines: [String]) throws {
        let body = lines.joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: historyPath)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: body.data(using: .utf8)!)
    }
}

private func codexLine(
    sessionID: String = "sess-1",
    ts: Double = 1_700_000_000,
    text: String
) -> String {
    let dict: [String: Any] = [
        "session_id": sessionID,
        "ts": ts,
        "text": text,
    ]
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

@Suite("CodexAdapter")
struct CodexAdapterTests {
    @Test("first-run loads every line in history")
    func firstRunLoadsAll() async throws {
        let fx = try CodexFixture()
        defer { fx.cleanup() }
        try fx.writeLines([
            codexLine(text: "one"),
            codexLine(ts: 1_700_000_100, text: "two"),
        ])
        let adapter = CodexAdapter(historyPath: fx.historyPath)
        let (entries, cursor) = try await adapter.load(cursor: nil)
        #expect(entries.count == 2)
        #expect(entries.map(\.text) == ["one", "two"])
        #expect(entries.allSatisfy { $0.agent == "codex" && $0.role == "user" })
        #expect(!cursor.isEmpty)
    }

    @Test("second run with cursor returns no new entries")
    func secondRunNoop() async throws {
        let fx = try CodexFixture()
        defer { fx.cleanup() }
        try fx.writeLines([codexLine(text: "only")])
        let adapter = CodexAdapter(historyPath: fx.historyPath)
        let (first, firstCursor) = try await adapter.load(cursor: nil)
        #expect(first.count == 1)
        let (second, secondCursor) = try await adapter.load(cursor: firstCursor)
        #expect(second.isEmpty)
        #expect(secondCursor == firstCursor)
    }

    @Test("missing history file returns no entries and does not throw")
    func missingFileReturnsEmpty() async throws {
        let fx = try CodexFixture()
        defer { fx.cleanup() }
        // Note: we never write the file.
        let adapter = CodexAdapter(historyPath: fx.historyPath)
        let (entries, cursor) = try await adapter.load(cursor: nil)
        #expect(entries.isEmpty)
        // Cursor encoded but represents offset 0.
        let decoded = CodexAdapter.decodeCursor(cursor)
        #expect(decoded.offset == 0)
    }

    @Test("entries with empty / whitespace text are skipped")
    func emptyTextSkipped() async throws {
        let fx = try CodexFixture()
        defer { fx.cleanup() }
        try fx.writeLines([
            codexLine(text: ""),
            codexLine(ts: 1_700_000_001, text: "   "),
            codexLine(ts: 1_700_000_002, text: "real"),
        ])
        let adapter = CodexAdapter(historyPath: fx.historyPath)
        let (entries, _) = try await adapter.load(cursor: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.text == "real")
    }

    @Test("appended lines after first load are picked up by second load")
    func incrementalAppend() async throws {
        let fx = try CodexFixture()
        defer { fx.cleanup() }
        try fx.writeLines([codexLine(text: "alpha")])
        let adapter = CodexAdapter(historyPath: fx.historyPath)
        let (_, c1) = try await adapter.load(cursor: nil)
        try fx.appendLines([codexLine(ts: 1_700_000_500, text: "beta")])
        let (entries, _) = try await adapter.load(cursor: c1)
        #expect(entries.count == 1)
        #expect(entries.first?.text == "beta")
    }
}
