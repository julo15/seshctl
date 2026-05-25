import Foundation
import Testing

@testable import SeshctlCore

@Suite("TranscriptLatestAssistantScanner")
struct TranscriptLatestAssistantScannerTests {

    @Test("single assistant text turn returns the trimmed text")
    func returnsLatestAssistantText() {
        let transcript = """
        {"type":"user","message":{"role":"user","content":"continue"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Working on it."}]}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == "Working on it.")
    }

    @Test("multi-block assistant turn — returns the text block")
    func returnsTextFromMultiBlockTurn() {
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"reasoning..."},{"type":"text","text":"Here's the answer."},{"type":"tool_use","name":"Read","input":{}}]}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == "Here's the answer.")
    }

    @Test("newest assistant turn is tool_use-only — returns nil (does NOT walk back)")
    func returnsNilWhenNewestAssistantIsToolUseOnly() {
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Earlier reply."}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"..."},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == nil)
    }

    @Test("newest assistant turn is thinking-only — returns nil")
    func returnsNilWhenNewestAssistantIsThinkingOnly() {
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"still reasoning..."}]}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == nil)
    }

    @Test("two assistant text turns — newest wins")
    func prefersNewestAssistantTurn() {
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"First reply."}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Second reply."}]}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == "Second reply.")
    }

    @Test("user turn after the latest assistant text — returns nil (pending-prompt-clears)")
    func returnsNilWhenUserTurnFollowsLatestAssistant() {
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Mid-stream reply."}]}}
        {"type":"user","message":{"role":"user","content":"actually, do this instead"}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == nil)
    }

    @Test("system/away_summary after assistant text does NOT clear — still returns assistant text")
    func returnsLatestAssistantWhenAwaySummaryFollowsIt() {
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Latest reply."}]}}
        {"type":"system","subtype":"away_summary","content":"Recap text."}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == "Latest reply.")
    }

    @Test("missing file returns nil (doesn't throw)")
    func returnsNilForMissingFile() {
        let path = "/tmp/seshctl-nonexistent-\(UUID().uuidString).jsonl"
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcriptPath: path)
        #expect(result == nil)
    }

    @Test("single malformed line, no assistant turns — returns nil")
    func returnsNilForMalformedLine() {
        let transcript = "not json at all"
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == nil)
    }

    @Test("malformed lines are skipped, valid assistant text still surfaces")
    func skipsMalformedLinesAndKeepsScanning() {
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Good reply."}]}}
        not json at all
        {"incomplete":
        {"type":"system","subtype":"turn_duration","durationMs":1000}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == "Good reply.")
    }

    @Test("whitespace-only text block — returns nil")
    func returnsNilForEmptyTextBlock() {
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"   \\n\\t  "}]}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == nil)
    }

    @Test("wrapper whitespace trimmed, internal newlines preserved")
    func trimsWrapperWhitespace() {
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\\n\\n  Line one.\\nLine two.\\n\\nLine four.  \\n  "}]}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == "Line one.\nLine two.\n\nLine four.")
    }
}
