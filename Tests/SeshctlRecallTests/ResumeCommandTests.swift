import Testing

@testable import SeshctlRecall

@Suite("RecallStack.resumeCommand")
struct ResumeCommandTests {
    private func entry(agent: String) -> HistoryEntry {
        HistoryEntry(
            agent: agent,
            role: "user",
            sessionID: "abc-123",
            project: "/tmp/project",
            timestamp: 0,
            text: "hello",
            textHash: HistoryEntry.textHash(for: "hello")
        )
    }

    @Test("Claude resumes with the --resume flag")
    func claude() {
        #expect(RecallStack.resumeCommand(for: entry(agent: "claude")) == "claude --resume abc-123")
    }

    @Test("Codex resumes with the resume subcommand")
    func codex() {
        #expect(RecallStack.resumeCommand(for: entry(agent: "codex")) == "codex resume abc-123")
    }

    @Test("Gemini has no per-session resume")
    func gemini() {
        #expect(RecallStack.resumeCommand(for: entry(agent: "gemini")) == "gemini")
    }

    @Test("Cursor and unknown agents get no resume command")
    func noResume() {
        #expect(RecallStack.resumeCommand(for: entry(agent: "cursor")) == "")
        #expect(RecallStack.resumeCommand(for: entry(agent: "mystery")) == "")
    }
}
