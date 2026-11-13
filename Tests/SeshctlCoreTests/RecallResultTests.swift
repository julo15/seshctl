import Foundation
import Testing

@testable import SeshctlCore

@Suite("RecallResult")
struct RecallResultTests {

    @Test("Decodes JSON from real recall output")
    func decodesRealRecallOutput() throws {
        let json = """
            [{"agent": "claude", "role": "user", "session_id": "abc-123", \
            "project": "/Users/me/myapp", "timestamp": 1773696403.194, \
            "score": 0.658, \
            "resume_cmd": "cd /Users/me/myapp && claude --resume abc-123", \
            "text": "how do we fix the auth bug?"}]
            """
        let results = try JSONDecoder().decode([RecallResult].self, from: Data(json.utf8))

        #expect(results.count == 1)
        let r = results[0]
        #expect(r.agent == "claude")
        #expect(r.role == "user")
        #expect(r.sessionId == "abc-123")
        #expect(r.project == "/Users/me/myapp")
        #expect(r.timestamp == 1773696403.194)
        #expect(r.score == 0.658)
        #expect(r.resumeCmd == "cd /Users/me/myapp && claude --resume abc-123")
        #expect(r.text == "how do we fix the auth bug?")
    }

    @Test("Decodes empty array")
    func decodesEmptyArray() throws {
        let results = try JSONDecoder().decode([RecallResult].self, from: Data("[]".utf8))
        #expect(results.isEmpty)
    }

    @Test("Decodes multiple results")
    func decodesMultipleResults() throws {
        let json = """
            [
              {"agent": "claude", "role": "user", "session_id": "s1", \
            "project": "/p1", "timestamp": 1000.0, "score": 0.9, \
            "resume_cmd": "cmd1", "text": "first"},
              {"agent": "codex", "role": "assistant", "session_id": "s2", \
            "project": "/p2", "timestamp": 2000.0, "score": 0.5, \
            "resume_cmd": "cmd2", "text": "second"},
              {"agent": "claude", "role": "user", "session_id": "s3", \
            "project": "/p3", "timestamp": 3000.0, "score": 0.1, \
            "resume_cmd": "cmd3", "text": "third"}
            ]
            """
        let results = try JSONDecoder().decode([RecallResult].self, from: Data(json.utf8))

        #expect(results.count == 3)
        #expect(results[0].sessionId == "s1")
        #expect(results[1].agent == "codex")
        #expect(results[2].text == "third")
    }

    @Test("Snake-case mapping works for sessionId and resumeCmd")
    func snakeCaseMapping() throws {
        let json = """
            {"agent": "claude", "role": "user", "session_id": "mapped-id", \
            "project": "/proj", "timestamp": 100.0, "score": 0.5, \
            "resume_cmd": "mapped-cmd", "text": "hello"}
            """
        let result = try JSONDecoder().decode(RecallResult.self, from: Data(json.utf8))

        #expect(result.sessionId == "mapped-id")
        #expect(result.resumeCmd == "mapped-cmd")
    }

    @Test("Round-trip encoding and decoding preserves all fields")
    func roundTrip() throws {
        let original = RecallResult(
            agent: "claude",
            role: "assistant",
            sessionId: "rt-456",
            project: "/Users/me/project",
            timestamp: 1773700000.123,
            score: 0.842,
            resumeCmd: "cd /Users/me/project && claude --resume rt-456",
            text: "the auth fix is in middleware.swift"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecallResult.self, from: data)

        #expect(decoded.agent == original.agent)
        #expect(decoded.role == original.role)
        #expect(decoded.sessionId == original.sessionId)
        #expect(decoded.project == original.project)
        #expect(decoded.timestamp == original.timestamp)
        #expect(decoded.score == original.score)
        #expect(decoded.resumeCmd == original.resumeCmd)
        #expect(decoded.text == original.text)
    }

    @Test("Decodes without a snippet (semantic and legacy JSON)")
    func decodesWithoutSnippet() throws {
        let json = """
            {"agent": "claude", "role": "user", "session_id": "s", "project": "/p", \
            "timestamp": 1, "score": 0.5, "resume_cmd": "", "text": "t"}
            """
        let r = try JSONDecoder().decode(RecallResult.self, from: Data(json.utf8))
        #expect(r.snippet == nil)
    }

    @Test("snippetSegments splits marked runs and collapses whitespace")
    func snippetSegmentsSplitsRuns() {
        let s = "…fix the \u{1}appcast\u{2}  and\n\n\u{1}sparkle\u{2} keys…"
        let segments = RecallResult.snippetSegments(s)
        #expect(segments.map(\.text) == ["…fix the ", "appcast", " and ", "sparkle", " keys…"])
        #expect(segments.map(\.isMatch) == [false, true, false, true, false])
    }

    @Test("snippetSegments trims the ends and handles a snippet that is all match")
    func snippetSegmentsEdges() {
        #expect(RecallResult.snippetSegments("  \u{1}appcast\u{2}  ").map(\.text) == ["appcast"])
        #expect(RecallResult.snippetSegments("plain text").map(\.isMatch) == [false])
        #expect(RecallResult.snippetSegments("").isEmpty)
    }

    @Test("snippetSegments merges adjacent matches")
    func snippetSegmentsMergesAdjacent() {
        let segments = RecallResult.snippetSegments("\u{1}make\u{2}\u{1}file\u{2} x")
        #expect(segments.map(\.text) == ["makefile", " x"])
    }
}
