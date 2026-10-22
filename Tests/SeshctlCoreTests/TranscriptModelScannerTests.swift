import Foundation
import Testing

@testable import SeshctlCore

@Suite("TranscriptModelScanner")
struct TranscriptModelScannerTests {
    private func claudeAssistant(_ model: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","model":"\#(model)","content":[{"type":"text","text":"hi"}]}}"#
    }

    @Test("Claude: the newest assistant record's model wins")
    func claudeLatestWins() {
        let transcript = [
            claudeAssistant("claude-opus-5"),
            #"{"type":"user","message":{"role":"user","content":"switch"}}"#,
            claudeAssistant("claude-fable-5-1"),
            #"{"type":"system","subtype":"away_summary","content":"recap"}"#,
        ].joined(separator: "\n")

        #expect(TranscriptModelScanner.extractModel(transcript: transcript, tool: .claude) == "claude-fable-5-1")
    }

    @Test("Claude: <synthetic> interrupts are skipped")
    func claudeSkipsSynthetic() {
        let transcript = [claudeAssistant("claude-opus-5-5"), claudeAssistant("<synthetic>")].joined(separator: "\n")

        #expect(TranscriptModelScanner.extractModel(transcript: transcript, tool: .claude) == "claude-opus-5-5")
    }

    @Test("Codex: the newest turn_context model wins")
    func codexTurnContext() {
        let transcript = [
            #"{"type":"session_meta","payload":{"id":"x"}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.5","cwd":"/tmp"}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-terra","cwd":"/tmp"}}"#,
            #"{"type":"response_item","payload":{"type":"message"}}"#,
        ].joined(separator: "\n")

        #expect(TranscriptModelScanner.extractModel(transcript: transcript, tool: .codex) == "gpt-5.6-terra")
    }

    @Test("Each tool reads only its own record shape")
    func toolShapesDontCross() {
        let claude = claudeAssistant("claude-opus-5-5")
        let codex = #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#

        #expect(TranscriptModelScanner.extractModel(transcript: codex, tool: .claude) == nil)
        #expect(TranscriptModelScanner.extractModel(transcript: claude, tool: .codex) == nil)
        #expect(TranscriptModelScanner.extractModel(transcript: claude, tool: .gemini) == nil)
        #expect(TranscriptModelScanner.extractModel(transcript: claude, tool: .cursor) == nil)
    }

    @Test("No model record, or malformed lines, gives nil")
    func noModel() {
        let transcript = [#"{"type":"user","message":{"content":"hi"}}"#, #"{"model": broken"#].joined(separator: "\n")

        #expect(TranscriptModelScanner.extractModel(transcript: transcript, tool: .claude) == nil)
    }

    @Test("Reads from a file on disk")
    func readsFile() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        try (claudeAssistant("claude-opus-5-5") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(TranscriptModelScanner.extractModel(transcriptPath: path, tool: .claude) == "claude-opus-5-5")
        #expect(TranscriptModelScanner.extractModel(transcriptPath: path + ".missing", tool: .claude) == nil)
    }

    @Test(
        "Display names are short",
        arguments: [
            ("claude-opus-5-5", "Opus 5.5"),
            ("claude-fable-5-1", "Fable 5.1"),
            ("claude-opus-5", "Opus 5"),
            ("claude-haiku-4-5-20251001", "Haiku 4.5"),
            ("claude-opus-4-6[1m]", "Opus 4.6"),
            ("gpt-5.5", "GPT-5.5"),
            ("gpt-5.3-codex", "GPT-5.3"),
            ("gpt-5.6-terra", "GPT-5.6 Terra"),
            ("some-new-model", "some-new-model"),
        ]
    )
    func displayNames(raw: String, expected: String) {
        #expect(TranscriptModelScanner.displayName(for: raw) == expected)
    }
}
