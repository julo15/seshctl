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

    @Test("trailing tool_use sub-event in same turn — preserves text (split-event JSONL)")
    func preservesTextWhenToolUseFollowsInSameTurn() {
        // Real Claude Code JSONL fans a single logical turn out into one
        // event per content block. The trailing tool_use event must NOT
        // clobber the narration that preceded it — that's the
        // AskUserQuestion / juplan-row bug.
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"..."}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I've got enough to form a diagnosis."}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion","input":{}}]}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == "I've got enough to form a diagnosis.")
    }

    @Test("new turn (after user event) with only thinking / tool_use sub-events — returns nil")
    func returnsNilWhenNewTurnAfterUserHasNoText() {
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Earlier reply."}]}}
        {"type":"user","message":{"role":"user","content":"continue"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"..."}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == nil)
    }

    @Test("malformed assistant event (missing content) preserves prior text — does NOT clear")
    func malformedAssistantEventPreservesPriorText() {
        // Consistent with `skipsMalformedLinesAndKeepsScanning`: isolated
        // parse glitches shouldn't lose valid prior data.
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Earlier text"}]}}
        {"type":"assistant","message":{"role":"assistant"}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == "Earlier text")
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

    @Test("fresh user prompt after assistant text clears (symmetry with the keep-case)")
    func clearsLatestAssistantWhenFreshUserPromptFollowsIt() {
        // Twin of `keepsLatestAssistantWhenToolResultFollowsIt`: a fresh
        // prompt is a real turn boundary, so the row should fall through to
        // lastAsk and show `You: <new prompt>`. Same observable behavior as
        // `returnsNilWhenUserTurnFollowsLatestAssistant`; named for symmetry
        // with the keep-case so the keep/clear pair reads as one rule.
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Mid-stream reply."}]}}
        {"type":"user","message":{"role":"user","content":"actually do this instead"}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == nil)
    }

    @Test("tool_result user event after assistant text — preserves the text")
    func keepsLatestAssistantWhenToolResultFollowsIt() {
        // Tool_result-only user events are continuations, not turn
        // boundaries. The row should keep showing the latest assistant
        // narration ("Looking at the auth file…") while the tool runs,
        // instead of regressing to `You: <stale prompt>`.
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking at the auth file…"}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"file contents"}]}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == "Looking at the auth file…")
    }

    @Test("interleaved tool_use / tool_result chain — original assistant text survives")
    func keepsLatestAssistantAcrossInterleavedToolResults() {
        // Multi-tool chains with no narration between calls (Read → Read,
        // Grep → Grep, etc.) must not drop the prior text. The row should
        // pin on "Reading the file..." for as long as the chain runs.
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Reading the file..."}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"path":"foo"}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"first result"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"path":"bar"}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b","content":"second result"}]}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == "Reading the file...")
    }

    @Test("tool_result user event then next assistant text — returns the new text")
    func surfacesNextAssistantTextAfterToolResult() {
        // Pins the next-text-wins behavior on the common Bash flow: the
        // text survives the tool_result user event (which no longer clears
        // pendingText — it's a continuation, not a turn boundary), and is
        // then overwritten by the next assistant text block ("Found the
        // answer."). The newest assistant text always wins within a turn.
        let transcript = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Reading the file..."}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"cat foo"}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"file contents"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Found the answer."}]}}
        """
        let result = TranscriptLatestAssistantScanner.extractLatestAssistantText(transcript: transcript)
        #expect(result == "Found the answer.")
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
