import Foundation
import Testing

@testable import SeshctlCore

@Suite("SessionTitler")
struct SessionTitlerTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func user(_ text: String, offset: TimeInterval = 0) -> ConversationTurn {
        .userMessage(text: text, timestamp: base.addingTimeInterval(offset))
    }

    private func assistant(_ text: String, offset: TimeInterval = 0) -> ConversationTurn {
        .assistantMessage(text: text, toolCalls: [], timestamp: base.addingTimeInterval(offset))
    }

    // MARK: - Readiness

    @Test("No first exchange when the assistant has not replied")
    func notReadyWithoutAssistant() {
        #expect(!SessionTitler.hasCompleteFirstExchange(turns: []))
        #expect(!SessionTitler.hasCompleteFirstExchange(turns: [user("fix the parser")]))
    }

    @Test("A tool-only assistant turn does not complete the first exchange")
    func toolOnlyTurnIsNotAReply() {
        let turns: [ConversationTurn] = [
            user("fix the parser"),
            .assistantMessage(
                text: "",
                toolCalls: [ToolCallSummary(toolName: "Read")],
                timestamp: base.addingTimeInterval(1)
            ),
        ]
        #expect(!SessionTitler.hasCompleteFirstExchange(turns: turns))
    }

    @Test("First exchange completes once the assistant produces text")
    func readyAfterAssistantText() {
        let turns = [user("fix the parser"), assistant("Looking at it now.", offset: 1)]
        #expect(SessionTitler.hasCompleteFirstExchange(turns: turns))
    }

    @Test("An assistant turn before any user turn does not count")
    func assistantBeforeUserDoesNotCount() {
        let turns = [assistant("Session resumed.", offset: -1), user("fix the parser")]
        #expect(!SessionTitler.hasCompleteFirstExchange(turns: turns))
    }

    // MARK: - Excerpt selection

    @Test("Opening material uses the first exchange, not later turns")
    func openingUsesFirstExchange() throws {
        let turns = [
            user("rebalance the repo accent palette"),
            assistant("Half the palette is orange.", offset: 1),
            user("also fix the icon", offset: 2),
            assistant("There is no icon at all.", offset: 3),
        ]
        let excerpt = try #require(SessionTitler.excerpt(turns: turns, material: .opening))
        #expect(excerpt.contains("rebalance the repo accent palette"))
        #expect(excerpt.contains("Half the palette is orange."))
        #expect(!excerpt.contains("also fix the icon"))
    }

    @Test("Latest material uses recent turns, not the opening")
    func latestUsesRecentTurns() throws {
        var turns: [ConversationTurn] = [user("original task")]
        for index in 1...10 {
            turns.append(assistant("reply \(index)", offset: TimeInterval(index)))
        }
        let excerpt = try #require(SessionTitler.excerpt(turns: turns, material: .latest))
        #expect(excerpt.contains("reply 10"))
        #expect(!excerpt.contains("original task"))
    }

    @Test("Away summaries are excluded from the excerpt")
    func excludesAwaySummary() throws {
        let turns: [ConversationTurn] = [
            user("fix the parser"),
            .awaySummary(text: "Shipped two PRs today.", timestamp: base.addingTimeInterval(1)),
            assistant("On it.", offset: 2),
        ]
        let excerpt = try #require(SessionTitler.excerpt(turns: turns, material: .opening))
        #expect(!excerpt.contains("Shipped two PRs"))
    }

    @Test("Returns nil when there is nothing to title")
    func nilWhenEmpty() {
        #expect(SessionTitler.excerpt(turns: [], material: .opening) == nil)
        #expect(SessionTitler.excerpt(turns: [], material: .latest) == nil)
    }

    @Test("Long turns are truncated so one paste cannot dominate the prompt")
    func condensesLongTurns() throws {
        let huge = String(repeating: "x", count: 5000)
        let excerpt = try #require(
            SessionTitler.excerpt(turns: [user(huge), assistant("ok", offset: 1)], material: .opening)
        )
        #expect(excerpt.count < 1500)
        #expect(excerpt.contains("\u{2026}"))
    }

    // MARK: - Normalization

    @Test("Strips the OSC terminal-title escape claude -p emits")
    func stripsOSC() {
        let raw = "\u{1B}]0;claude:0636\u{07}Add repo descriptions to clarify panels\u{1B}]0;claude \u{07}"
        #expect(SessionTitler.normalize(raw) == "Add repo descriptions to clarify panels")
    }

    @Test("Strips ANSI color sequences")
    func stripsANSI() {
        #expect(SessionTitler.normalize("\u{1B}[1;32mFix the Codex parser\u{1B}[0m") == "Fix the Codex parser")
    }

    @Test("Strips surrounding quotes and trailing punctuation")
    func stripsQuotesAndPunctuation() {
        #expect(SessionTitler.normalize("\"Fix the Codex parser\"") == "Fix the Codex parser")
        #expect(SessionTitler.normalize("Fix the Codex parser.") == "Fix the Codex parser")
        #expect(SessionTitler.normalize("\u{201C}Fix the Codex parser\u{201D}") == "Fix the Codex parser")
    }

    @Test("Keeps an apostrophe that is not a wrapping quote")
    func keepsInnerApostrophe() {
        #expect(SessionTitler.normalize("Fix Codex's transcript parser") == "Fix Codex's transcript parser")
    }

    @Test("Takes the first non-empty line when the model adds a preamble")
    func takesFirstContentLine() {
        #expect(SessionTitler.normalize("\n\nRebalance the accent palette\nSome trailing note") == "Rebalance the accent palette")
    }

    @Test("Enforces the word cap the prompt asks for")
    func enforcesWordCap() throws {
        let raw = "one two three four five six seven eight nine ten"
        let title = try #require(SessionTitler.normalize(raw))
        #expect(title.split(separator: " ").count == SessionTitler.maxWords)
        #expect(title == "one two three four five six seven eight")
    }

    @Test("Enforces the character cap for a single overlong token")
    func enforcesCharacterCap() throws {
        let title = try #require(SessionTitler.normalize(String(repeating: "x", count: 200)))
        #expect(title.count <= SessionTitler.maxCharacters + 1)  // +1 for the ellipsis
    }

    @Test("Returns nil for empty or escape-only output")
    func nilForEmptyOutput() {
        #expect(SessionTitler.normalize("") == nil)
        #expect(SessionTitler.normalize("   \n  ") == nil)
        #expect(SessionTitler.normalize("\u{1B}]0;claude\u{07}") == nil)
    }

    // MARK: - CLI resolution

    @Test("Prefers the native installer path over Homebrew")
    func prefersNativeInstallPath() {
        let candidates = SessionTitler.claudeCLICandidates(home: "/Users/test")
        #expect(candidates.first == "/Users/test/.local/bin/claude")
        #expect(candidates.contains("/opt/homebrew/bin/claude"))
    }

    @Test("Resolution returns nil when no candidate is executable")
    func resolutionNilWhenAbsent() {
        #expect(SessionTitler.resolveClaudeCLI(home: "/nonexistent-home-\(UUID().uuidString)") == nil)
    }

    // MARK: - Generation

    @Test("Generation normalizes the CLI's stdout")
    func generationNormalizes() {
        let title = SessionTitler.generate(
            excerpt: "User: fix it",
            cli: URL(fileURLWithPath: "/bin/true")
        ) { _, _, _, _ in
            ShellRunner.Result(stdout: "\u{1B}]0;claude\u{07}\"Fix the thing.\"", stderr: "", status: 0)
        }
        #expect(title == "Fix the thing")
    }

    @Test("Generation returns nil on non-zero exit")
    func generationNilOnFailure() {
        let title = SessionTitler.generate(
            excerpt: "User: fix it",
            cli: URL(fileURLWithPath: "/bin/true")
        ) { _, _, _, _ in
            ShellRunner.Result(stdout: "", stderr: "quota exceeded", status: 1)
        }
        #expect(title == nil)
    }

    @Test("Generation returns nil when the subprocess never launched")
    func generationNilOnLaunchFailure() {
        let title = SessionTitler.generate(
            excerpt: "User: fix it",
            cli: URL(fileURLWithPath: "/bin/true")
        ) { _, _, _, _ in nil }
        #expect(title == nil)
    }

    @Test("Generation passes the model and non-interactive flags")
    func generationPassesFlags() {
        var captured: [String] = []
        _ = SessionTitler.generate(
            excerpt: "User: fix it",
            cli: URL(fileURLWithPath: "/bin/true"),
            model: "haiku"
        ) { _, args, _, _ in
            captured = args
            return ShellRunner.Result(stdout: "Title", stderr: "", status: 0)
        }
        #expect(captured.contains("-p"))
        #expect(captured.contains("--model"))
        #expect(captured.contains("haiku"))
        // Without this the CLI emits its interactive stream format.
        #expect(captured.contains("--output-format"))
        #expect(captured.contains("text"))
    }

    @Test("Generation marks the subprocess as an internal session")
    func generationMarksSubprocess() {
        var captured: [String: String]?
        _ = SessionTitler.generate(
            excerpt: "User: fix it",
            cli: URL(fileURLWithPath: "/bin/true")
        ) { _, _, _, environment in
            captured = environment
            return ShellRunner.Result(stdout: "Title", stderr: "", status: 0)
        }
        // Without the marker the titling run's own SessionStart hook records a
        // row whose only content is the prompt naming some other session.
        #expect(captured?[InternalSession.environmentKey] == "1")
        #expect(InternalSession.isMarked(environment: captured ?? [:]))
    }
}
