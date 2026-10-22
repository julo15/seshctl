import Foundation
import Testing

@testable import SeshctlCore

@Suite("CodexThreadNameIndex")
struct CodexThreadNameIndexTests {

    private func fold(_ text: String) -> [String: String] {
        var state = CodexThreadNameIndex.State()
        CodexThreadNameIndex.fold(Data(text.utf8), into: &state)
        return state.names
    }

    private func tempIndex(_ text: String) throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func append(_ text: String, to path: String) throws {
        let handle = try #require(FileHandle(forWritingAtPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - indexPath(forRolloutPath:)

    @Test("index sits in the Codex home above sessions/YYYY/MM/DD")
    func indexPathFromRollout() {
        let rollout = "/Users/me/.agents/sessions/2026/10/22/rollout-2026-10-22T16-10-06-01a1653c.jsonl"
        #expect(CodexThreadNameIndex.indexPath(forRolloutPath: rollout) == "/Users/me/.agents/session_index.jsonl")
    }

    @Test("paths not shaped like a Codex rollout have no index", arguments: [
        "/tmp/abc.jsonl",
        "/Users/me/.codex/sessions/2026/10/22/notes.jsonl",
        "/Users/me/.codex/archive/2026/10/22/rollout-x.jsonl",
        "sessions/2026/10/22/rollout-x.jsonl",
    ])
    func indexPathRejectsOtherPaths(path: String) {
        #expect(CodexThreadNameIndex.indexPath(forRolloutPath: path) == nil)
    }

    // MARK: - fold

    @Test("last line per id wins, so the generated name replaces the prompt")
    func lastLineWins() {
        let names = fold("""
        {"id":"a","thread_name":"what do you know about my job at gol","updated_at":"t1"}
        {"id":"b","thread_name":"Fix flaky test","updated_at":"t2"}
        {"id":"a","thread_name":"Describe Golfzon job knowledge","updated_at":"t3"}

        """)
        #expect(names == ["a": "Describe Golfzon job knowledge", "b": "Fix flaky test"])
    }

    @Test("blank names, missing fields and malformed lines are skipped")
    func skipsBadLines() {
        let names = fold("""
        {"id":"a","thread_name":"Kept"}
        {"id":"a","thread_name":"   "}
        {"id":"b"}
        {"thread_name":"No id"}
        not json
        {"id":"c","thread_name":"  Trimmed  "}

        """)
        #expect(names == ["a": "Kept", "c": "Trimmed"])
    }

    // MARK: - scan

    @Test("missing file returns nil")
    func missingFile() {
        #expect(CodexThreadNameIndex.scan(indexPath: "/nonexistent/\(UUID().uuidString)", resuming: nil) == nil)
    }

    @Test("resumed scan reads only appended lines and keeps earlier names")
    func resumesFromOffset() throws {
        let path = try tempIndex(#"{"id":"a","thread_name":"Alpha"}"# + "\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try #require(CodexThreadNameIndex.scan(indexPath: path, resuming: nil))
        #expect(first.names == ["a": "Alpha"])

        try append(#"{"id":"b","thread_name":"Beta"}"# + "\n", to: path)
        let second = try #require(CodexThreadNameIndex.scan(indexPath: path, resuming: first))
        #expect(second.names == ["a": "Alpha", "b": "Beta"])
        #expect(second.offset > first.offset)

        let unchanged = try #require(CodexThreadNameIndex.scan(indexPath: path, resuming: second))
        #expect(unchanged == second)
    }

    @Test("a trailing line without a newline waits until it is complete")
    func partialTrailingLine() throws {
        let path = try tempIndex(#"{"id":"a","thread_name":"Alpha"}"# + "\n" + #"{"id":"b","thread_na"#)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try #require(CodexThreadNameIndex.scan(indexPath: path, resuming: nil))
        #expect(first.names == ["a": "Alpha"])

        try append(#"me":"Beta"}"# + "\n", to: path)
        let second = try #require(CodexThreadNameIndex.scan(indexPath: path, resuming: first))
        #expect(second.names == ["a": "Alpha", "b": "Beta"])
    }

    @Test("a file shorter than the saved offset is rescanned from scratch")
    func rewrittenFileRestarts() throws {
        let path = try tempIndex("""
        {"id":"a","thread_name":"Alpha"}
        {"id":"b","thread_name":"Beta"}

        """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try #require(CodexThreadNameIndex.scan(indexPath: path, resuming: nil))

        try (#"{"id":"c","thread_name":"C"}"# + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let second = try #require(CodexThreadNameIndex.scan(indexPath: path, resuming: first))
        #expect(second.names == ["c": "C"])
    }
}
