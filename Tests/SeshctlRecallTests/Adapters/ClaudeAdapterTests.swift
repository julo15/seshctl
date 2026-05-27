// ClaudeAdapterTests — exercises the per-file resumable cursor, tag stripping,
// and project resolution against synthetic transcript fixtures. Tests never
// touch `~/.claude/projects`; every run gets its own temp `projectsDir`.

import Foundation
import Testing

@testable import SeshctlRecall

private struct ClaudeFixture {
    let projectsDir: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("seshctl-claude-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true, attributes: nil
        )
        self.projectsDir = base
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: projectsDir)
    }

    /// Create a project subdir and a transcript file in it. Returns the
    /// transcript URL.
    func writeTranscript(
        projectDirName: String,
        sessionID: String,
        lines: [String]
    ) throws -> URL {
        let projectDir = projectsDir.appendingPathComponent(projectDirName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDir, withIntermediateDirectories: true, attributes: nil
        )
        let url = projectDir.appendingPathComponent("\(sessionID).jsonl")
        let body = lines.joined(separator: "\n") + "\n"
        try body.data(using: .utf8)!.write(to: url)
        return url
    }

    func appendToTranscript(_ url: URL, lines: [String]) throws {
        let body = lines.joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: body.data(using: .utf8)!)
    }
}

private func userLine(
    cwd: String? = nil,
    text: String,
    timestamp: String = "2026-05-25T10:00:00.000Z"
) -> String {
    var dict: [String: Any] = [
        "type": "user",
        "timestamp": timestamp,
        "message": ["content": text],
    ]
    if let cwd { dict["cwd"] = cwd }
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

private func assistantLine(
    text: String,
    timestamp: String = "2026-05-25T10:00:01.000Z"
) -> String {
    let dict: [String: Any] = [
        "type": "assistant",
        "timestamp": timestamp,
        "message": ["content": [["type": "text", "text": text]]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

@Suite("ClaudeAdapter")
struct ClaudeAdapterTests {
    @Test("first-run loads all user+assistant entries from every transcript")
    func firstRunLoadsAll() async throws {
        let fx = try ClaudeFixture()
        defer { fx.cleanup() }
        _ = try fx.writeTranscript(
            projectDirName: "-Users-julianlo-projects-app",
            sessionID: "abc",
            lines: [
                userLine(cwd: "/Users/julianlo/projects/app", text: "hello"),
                assistantLine(text: "hi back"),
            ]
        )
        _ = try fx.writeTranscript(
            projectDirName: "-tmp-other",
            sessionID: "def",
            lines: [userLine(cwd: "/tmp/other", text: "second")]
        )

        let adapter = ClaudeAdapter(projectsDir: fx.projectsDir)
        let (entries, cursor) = try await adapter.load(cursor: nil)

        #expect(entries.count == 3)
        let texts = Set(entries.map(\.text))
        #expect(texts == ["hello", "hi back", "second"])
        #expect(!cursor.isEmpty)
        // Hash present.
        for entry in entries {
            #expect(entry.textHash == HistoryEntry.textHash(for: entry.text))
        }
    }

    @Test("second run with cursor reports no new entries")
    func secondRunNoop() async throws {
        let fx = try ClaudeFixture()
        defer { fx.cleanup() }
        _ = try fx.writeTranscript(
            projectDirName: "-tmp-x",
            sessionID: "s1",
            lines: [userLine(cwd: "/tmp/x", text: "first message")]
        )

        let adapter = ClaudeAdapter(projectsDir: fx.projectsDir)
        let (firstEntries, firstCursor) = try await adapter.load(cursor: nil)
        #expect(firstEntries.count == 1)

        let (secondEntries, secondCursor) = try await adapter.load(cursor: firstCursor)
        #expect(secondEntries.isEmpty)
        // Cursor stays stable (file unchanged).
        #expect(secondCursor == firstCursor)
    }

    @Test("appended lines are ingested incrementally")
    func appendedLinesIngestIncrementally() async throws {
        let fx = try ClaudeFixture()
        defer { fx.cleanup() }
        let url = try fx.writeTranscript(
            projectDirName: "-tmp-y",
            sessionID: "s2",
            lines: [userLine(cwd: "/tmp/y", text: "alpha")]
        )

        let adapter = ClaudeAdapter(projectsDir: fx.projectsDir)
        let (firstEntries, firstCursor) = try await adapter.load(cursor: nil)
        #expect(firstEntries.count == 1)

        try fx.appendToTranscript(url, lines: [userLine(text: "beta")])

        let (secondEntries, secondCursor) = try await adapter.load(cursor: firstCursor)
        #expect(secondEntries.count == 1)
        #expect(secondEntries.first?.text == "beta")
        // cwd is sticky — second-run entry should inherit the project from the
        // first line's cwd.
        #expect(secondEntries.first?.project == "/tmp/y")
        #expect(secondCursor != firstCursor)
    }

    @Test("internal tags are stripped from message text")
    func tagStrippingRemovesSystemReminder() async throws {
        let fx = try ClaudeFixture()
        defer { fx.cleanup() }
        let messy = "real content<system-reminder>secret\nmultiline</system-reminder> tail"
        _ = try fx.writeTranscript(
            projectDirName: "-tmp-z",
            sessionID: "s3",
            lines: [userLine(cwd: "/tmp/z", text: messy)]
        )

        let adapter = ClaudeAdapter(projectsDir: fx.projectsDir)
        let (entries, _) = try await adapter.load(cursor: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.text.contains("secret") == false)
        #expect(entries.first?.text.contains("real content") == true)
        #expect(entries.first?.text.contains(" tail") == true)
    }

    @Test("entry whose content is wholly tags is skipped")
    func wholeTagsEntryIsSkipped() async throws {
        let fx = try ClaudeFixture()
        defer { fx.cleanup() }
        _ = try fx.writeTranscript(
            projectDirName: "-tmp-skip",
            sessionID: "s4",
            lines: [
                userLine(cwd: "/tmp/skip", text: "<system-reminder>only</system-reminder>"),
                userLine(text: "kept"),
            ]
        )

        let adapter = ClaudeAdapter(projectsDir: fx.projectsDir)
        let (entries, _) = try await adapter.load(cursor: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.text == "kept")
    }

    @Test("project falls back to decoded directory when cwd is absent")
    func projectFallbackToDecodedDir() async throws {
        let fx = try ClaudeFixture()
        defer { fx.cleanup() }
        // No cwd anywhere — adapter should decode the dir name.
        _ = try fx.writeTranscript(
            projectDirName: "-Users-julianlo-Documents-me-app",
            sessionID: "ss",
            lines: [userLine(text: "no cwd here")]
        )

        let adapter = ClaudeAdapter(projectsDir: fx.projectsDir)
        let (entries, _) = try await adapter.load(cursor: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.project == "/Users/julianlo/Documents/me/app")
    }

    @Test("corrupted JSON line is skipped, surrounding lines still load")
    func corruptedLineSkipped() async throws {
        let fx = try ClaudeFixture()
        defer { fx.cleanup() }
        _ = try fx.writeTranscript(
            projectDirName: "-tmp-corrupt",
            sessionID: "sc",
            lines: [
                userLine(cwd: "/tmp/corrupt", text: "good before"),
                "not valid json {{{",
                userLine(text: "good after"),
            ]
        )

        let adapter = ClaudeAdapter(projectsDir: fx.projectsDir)
        let (entries, _) = try await adapter.load(cursor: nil)
        #expect(entries.count == 2)
        let texts = Set(entries.map(\.text))
        #expect(texts == ["good before", "good after"])
    }

    @Test("old `{offset: N}` cursor shape resets to empty")
    func legacyCursorReset() async throws {
        let fx = try ClaudeFixture()
        defer { fx.cleanup() }
        _ = try fx.writeTranscript(
            projectDirName: "-tmp-legacy",
            sessionID: "sl",
            lines: [userLine(cwd: "/tmp/legacy", text: "should reload")]
        )

        let legacy = Data("{\"offset\": 999}".utf8)
        let adapter = ClaudeAdapter(projectsDir: fx.projectsDir)
        let (entries, _) = try await adapter.load(cursor: legacy)
        #expect(entries.count == 1)
        #expect(entries.first?.text == "should reload")
    }
}
