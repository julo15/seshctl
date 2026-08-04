import Foundation
import Testing

@testable import SeshctlCore

@Suite("TranscriptModelScanner")
struct TranscriptModelScannerTests {

    // MARK: - Claude

    @Test("Reads message.model from a Claude assistant record")
    func readsClaudeModel() {
        let transcript = #"{"type":"assistant","message":{"model":"claude-opus-5","content":[]}}"#
        #expect(TranscriptModelScanner.extractModel(transcript: transcript, tool: .claude) == "claude-opus-5")
    }

    @Test("Takes the latest model when the session switches mid-run")
    func takesLatestClaudeModel() {
        let transcript = [
            #"{"type":"assistant","message":{"model":"claude-sonnet-5","content":[]}}"#,
            #"{"type":"user","message":{"content":"switch to opus"}}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5","content":[]}}"#,
        ].joined(separator: "\n")
        #expect(TranscriptModelScanner.extractModel(transcript: transcript, tool: .claude) == "claude-opus-5")
    }

    @Test("Ignores Claude's <synthetic> pseudo-model")
    func ignoresSynthetic() {
        // Written for locally-generated messages (interrupts, errors) that
        // never reached a model — surfacing it would put "<synthetic>" in the row.
        let transcript = [
            #"{"type":"assistant","message":{"model":"claude-opus-5","content":[]}}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[]}}"#,
        ].joined(separator: "\n")
        #expect(TranscriptModelScanner.extractModel(transcript: transcript, tool: .claude) == "claude-opus-5")
    }

    // MARK: - Codex

    @Test("Reads payload.model from a Codex turn_context record")
    func readsCodexModel() {
        // Codex's real shape: session_meta carries a null model, turn_context
        // carries the real one, so the scan must keep the last non-nil.
        let transcript = [
            #"{"timestamp":"2026-07-27T15:51:48Z","type":"session_meta","payload":{"session_id":"019fa445","model":null}}"#,
            #"{"timestamp":"2026-07-27T15:51:49Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        ].joined(separator: "\n")
        #expect(TranscriptModelScanner.extractModel(transcript: transcript, tool: .codex) == "gpt-5.6-sol")
    }

    @Test("Returns nil for a Codex transcript that records no model")
    func nilWhenCodexRecordsNoModel() {
        let transcript = [
            #"{"timestamp":"2026-07-27T15:51:48Z","type":"session_meta","payload":{"session_id":"019fa445","model":null}}"#,
            #"{"timestamp":"2026-07-27T15:51:49Z","type":"event_msg","payload":{"type":"task_started"}}"#,
        ].joined(separator: "\n")
        #expect(TranscriptModelScanner.extractModel(transcript: transcript, tool: .codex) == nil)
    }

    // MARK: - Pi

    @Test("Reads modelId from a Pi model_change record")
    func readsPiModel() {
        let transcript = [
            #"{"type":"session","version":3,"id":"abc","cwd":"/tmp"}"#,
            #"{"type":"model_change","timestamp":"2026-06-08T09:26:04Z","provider":"openai-codex","modelId":"gpt-5.5"}"#,
        ].joined(separator: "\n")
        // `provider: openai-codex` means Codex is Pi's *model provider* — it
        // does not make this a Codex transcript. See AGENTS.md.
        #expect(TranscriptModelScanner.extractModel(transcript: transcript, tool: .pi) == "gpt-5.5")
    }

    @Test("Takes the latest Pi model when the session switches provider")
    func takesLatestPiModel() {
        let transcript = [
            #"{"type":"model_change","provider":"github-copilot","modelId":"grok-code-fast-1"}"#,
            #"{"type":"model_change","provider":"openai-codex","modelId":"gpt-5.5"}"#,
        ].joined(separator: "\n")
        #expect(TranscriptModelScanner.extractModel(transcript: transcript, tool: .pi) == "gpt-5.5")
    }

    @Test("Codex and Pi record shapes do not cross over")
    func formatsDoNotCrossOver() {
        // The two families share one sessions/ folder, so each arm must ignore
        // the other's records rather than half-reading them.
        let pi = #"{"type":"model_change","provider":"openai-codex","modelId":"gpt-5.5"}"#
        let codex = #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#
        #expect(TranscriptModelScanner.extractModel(transcript: pi, tool: .codex) == nil)
        #expect(TranscriptModelScanner.extractModel(transcript: codex, tool: .pi) == nil)
    }

    // MARK: - Tools without transcripts

    @Test("Tools that write no transcript never report a model")
    func nilForTranscriptlessTools() {
        let transcript = #"{"type":"assistant","message":{"model":"claude-opus-5","content":[]}}"#
        #expect(TranscriptModelScanner.extractModel(transcript: transcript, tool: .cursor) == nil)
        #expect(TranscriptModelScanner.extractModel(transcript: transcript, tool: .gemini) == nil)
    }

    @Test("Returns nil for empty or malformed input")
    func nilForGarbage() {
        #expect(TranscriptModelScanner.extractModel(transcript: "", tool: .claude) == nil)
        #expect(TranscriptModelScanner.extractModel(transcript: "not json\n{oops", tool: .claude) == nil)
    }

    // MARK: - Display names

    @Test("Shortens Claude model ids")
    func shortensClaude() {
        #expect(TranscriptModelScanner.displayName(for: "claude-opus-5") == "Opus 5")
        #expect(TranscriptModelScanner.displayName(for: "claude-sonnet-5") == "Sonnet 5")
        #expect(TranscriptModelScanner.displayName(for: "claude-haiku-4-5") == "Haiku 4.5")
    }

    @Test("Drops the trailing build stamp from a dated Claude id")
    func dropsDateStamp() {
        #expect(TranscriptModelScanner.displayName(for: "claude-haiku-4-5-20251001") == "Haiku 4.5")
    }

    @Test("Shortens Codex model ids")
    func shortensCodex() {
        #expect(TranscriptModelScanner.displayName(for: "gpt-5.5") == "GPT-5.5")
        #expect(TranscriptModelScanner.displayName(for: "gpt-5.4") == "GPT-5.4")
        #expect(TranscriptModelScanner.displayName(for: "gpt-5.3-codex") == "GPT-5.3")
    }

    @Test("Passes unrecognized ids through unchanged")
    func passesThroughUnknown() {
        // Better verbose than mangled — a new vendor prefix should read oddly,
        // not incorrectly.
        #expect(TranscriptModelScanner.displayName(for: "llama-3-70b") == "llama-3-70b")
        #expect(TranscriptModelScanner.displayName(for: "") == "")
    }
}
