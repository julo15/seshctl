import Foundation
import Testing

@testable import SeshctlCore

@Suite("TranscriptAwaySummaryScanner")
struct TranscriptAwaySummaryScannerTests {

    @Test("empty transcript returns nil")
    func empty() {
        #expect(TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcript: "") == nil)
    }

    @Test("transcript with no away_summary events returns nil")
    func noAwaySummaryEvents() {
        let transcript = """
        {"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"local-uuid"}
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"role":"assistant","content":"hello"}}
        """
        #expect(TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcript: transcript) == nil)
    }

    @Test("single away_summary event returns its content")
    func singleAwaySummary() {
        let transcript = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"system","subtype":"away_summary","content":"Shipped one PR.","timestamp":"2026-05-06T17:48:04.022Z"}
        """
        let summary = TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcript: transcript)
        #expect(summary == "Shipped one PR.")
    }

    @Test("multiple away_summary events — most recent (last in file) wins")
    func multipleAwaySummariesLatestWins() {
        let transcript = """
        {"type":"system","subtype":"away_summary","content":"First summary."}
        {"type":"user","message":{"role":"user","content":"more work"}}
        {"type":"system","subtype":"away_summary","content":"Second summary."}
        """
        let summary = TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcript: transcript)
        #expect(summary == "Second summary.")
    }

    @Test("strips the trailing (disable recaps in /config) parenthetical and trims whitespace")
    func stripsRecapHint() {
        let transcript = """
        {"type":"system","subtype":"away_summary","content":"Shipped two PRs to main today: #31 and #32. (disable recaps in /config)"}
        """
        let summary = TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcript: transcript)
        #expect(summary == "Shipped two PRs to main today: #31 and #32.")
    }

    @Test("ignores system records with other subtypes")
    func nonAwaySystemEvents() {
        let transcript = """
        {"type":"system","subtype":"bridge_status","content":"/remote-control is active","url":"https://claude.ai/code/session_X"}
        {"type":"system","subtype":"turn_duration","content":"42s"}
        {"type":"user","message":{"role":"user","content":"hi"}}
        """
        #expect(TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcript: transcript) == nil)
    }

    @Test("malformed JSON lines don't crash the scan and don't affect later matches")
    func malformedLinesIgnored() {
        let transcript = """
        not json at all
        {"type":"system","subtype":"away_summary","content":"Good summary."}
        {"incomplete":
        """
        let summary = TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcript: transcript)
        #expect(summary == "Good summary.")
    }

    @Test("away_summary without a content field is skipped")
    func missingContentField() {
        let transcript = """
        {"type":"system","subtype":"away_summary","timestamp":"2026-05-06T17:48:04.022Z"}
        {"type":"system","subtype":"away_summary","content":"Real summary."}
        """
        let summary = TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcript: transcript)
        #expect(summary == "Real summary.")
    }

    @Test("reads a real temp file on disk")
    func readsFileFromDisk() throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        let content = """
        {"type":"system","subtype":"away_summary","content":"Summary from disk. (disable recaps in /config)"}
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcriptPath: path)
        #expect(summary == "Summary from disk.")
    }

    @Test("missing file returns nil (doesn't throw)")
    func missingFile() {
        let summary = TranscriptAwaySummaryScanner.extractLatestAwaySummary(
            transcriptPath: "/tmp/does-not-exist-\(UUID().uuidString).jsonl"
        )
        #expect(summary == nil)
    }

    // MARK: - Stale-recap invalidation
    //
    // A recap reflects "session is currently idle." Once a user prompt or
    // assistant reply lands *after* the latest recap, the session has
    // resumed and the recap is stale — callers want to fall through to
    // lastReply/lastAsk rather than pin the row to a no-longer-accurate
    // summary. Verified against the user-reported bug where the row stayed
    // stuck on a recap even after the conversation moved on.

    @Test("away_summary followed by a user message returns nil (recap is stale)")
    func userMessageAfterRecapInvalidates() {
        let transcript = """
        {"type":"system","subtype":"away_summary","content":"Recap from earlier."}
        {"type":"user","message":{"role":"user","content":"new turn"}}
        """
        #expect(TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcript: transcript) == nil)
    }

    @Test("away_summary followed by an assistant message returns nil (recap is stale)")
    func assistantMessageAfterRecapInvalidates() {
        let transcript = """
        {"type":"system","subtype":"away_summary","content":"Recap from earlier."}
        {"type":"assistant","message":{"role":"assistant","content":"new reply"}}
        """
        #expect(TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcript: transcript) == nil)
    }

    @Test("user/assistant turns between two recaps — second recap wins")
    func turnBetweenTwoRecapsLatestWins() {
        let transcript = """
        {"type":"system","subtype":"away_summary","content":"First recap."}
        {"type":"user","message":{"role":"user","content":"new turn"}}
        {"type":"assistant","message":{"role":"assistant","content":"reply"}}
        {"type":"system","subtype":"away_summary","content":"Second recap."}
        """
        #expect(TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcript: transcript) == "Second recap.")
    }

    @Test("recap is the very last event after a long conversation — still returned")
    func recapAtEndAfterConversation() {
        let transcript = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"role":"assistant","content":"hello"}}
        {"type":"user","message":{"role":"user","content":"more"}}
        {"type":"system","subtype":"away_summary","content":"Session ended on a recap."}
        """
        #expect(TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcript: transcript) == "Session ended on a recap.")
    }

    @Test("non-user/assistant records after a recap do NOT invalidate it")
    func nonTurnRecordsAfterRecapPreserveIt() {
        // System events that aren't user/assistant turns (e.g. permission-mode,
        // pr-link, file-history-snapshot, turn_duration, stop_hook_summary)
        // don't represent the session resuming. Only a real user prompt or
        // assistant reply does.
        let transcript = """
        {"type":"system","subtype":"away_summary","content":"Still idle."}
        {"type":"system","subtype":"turn_duration","durationMs":1000}
        {"type":"pr-link","prNumber":31}
        {"type":"file-history-snapshot"}
        """
        #expect(TranscriptAwaySummaryScanner.extractLatestAwaySummary(transcript: transcript) == "Still idle.")
    }
}
