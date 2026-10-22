import Foundation
import Testing

@testable import SeshctlCore

@Suite("TitleSuggester")
struct TitleSuggesterTests {
    private let t0 = Date(timeIntervalSince1970: 1000)

    private func ask(_ text: String) -> ConversationTurn { .userMessage(text: text, timestamp: t0) }
    private func reply(_ text: String) -> ConversationTurn { .assistantMessage(text: text, toolCalls: [], timestamp: t0) }

    @Test("The prompt carries the last 10 asks, the latest reply and the current title")
    func promptIsRecencyBiased() throws {
        let turns = (1...12).flatMap { [ask("ask \($0)"), reply("reply \($0)")] }

        let prompt = try #require(TitleSuggester.prompt(turns: turns, currentTitle: "Assess patoms PRs"))

        #expect(!prompt.contains("- ask 2\n"), "older asks fall out of the window")
        #expect(prompt.contains("- ask 3\n"))
        #expect(prompt.contains("- ask 12"))
        #expect(prompt.contains("Latest assistant reply:\nreply 12"))
        #expect(!prompt.contains("reply 11"), "only the latest reply")
        #expect(prompt.contains("Current title: Assess patoms PRs"))
        #expect(prompt.contains("task it is on NOW"))
    }

    @Test("Long turns are trimmed and whitespace collapsed")
    func longTurnsAreTrimmed() throws {
        let long = String(repeating: "word ", count: 200)
        let prompt = try #require(TitleSuggester.prompt(turns: [ask("multi\n\nline   ask"), reply(long)], currentTitle: nil))

        #expect(prompt.contains("- multi line ask"))
        #expect(prompt.contains("\u{2026}"))
        #expect(!prompt.contains("Current title"), "no title line without a title")
    }

    @Test("No user request, no prompt")
    func noAskNoPrompt() {
        #expect(TitleSuggester.prompt(turns: [reply("hello")], currentTitle: "x") == nil)
        #expect(TitleSuggester.prompt(turns: [ask("   ")], currentTitle: nil) == nil)
    }

    @Test("Candidates are cleaned, deduped and capped at three")
    func parsesCandidates() {
        let raw = "\u{1B}]0;claude\u{07}1. \"Right-align the model pill\"\n2) **Fix icon slot width**.\n\n- right-align the model pill\n• Tighten chevron spacing\n4. Fourth one"

        #expect(TitleSuggester.parseCandidates(raw) == [
            "Right-align the model pill",
            "Fix icon slot width",
            "Tighten chevron spacing",
        ])
    }

    @Test("Overlong candidates are cut to eight words")
    func capsWords() {
        #expect(TitleSuggester.parseCandidates("one two three four five six seven eight nine ten") == ["one two three four five six seven eight"])
    }

    @Test("generate runs Haiku without user settings or persistence, from a scratch directory")
    func generateArguments() {
        var captured: (args: [String], directory: URL?)?
        let titles = TitleSuggester.generate(prompt: "P", cli: URL(fileURLWithPath: "/bin/claude")) { _, args, _, directory in
            captured = (args, directory)
            return ShellRunner.Result(stdout: "A\nB\nC", stderr: "", status: 0)
        }

        #expect(titles == ["A", "B", "C"])
        let args = captured?.args ?? []
        #expect(args.contains("--no-session-persistence"))
        #expect(args.contains("--setting-sources") && args.contains("project"))
        #expect(args.contains("haiku"))
        #expect(args.last == "P")
        #expect(captured?.directory != nil)
    }

    @Test("A failed run gives no titles")
    func generateFailure() {
        let cli = URL(fileURLWithPath: "/bin/claude")
        #expect(TitleSuggester.generate(prompt: "P", cli: cli) { _, _, _, _ in
            ShellRunner.Result(stdout: "A", stderr: "quota", status: 1)
        }.isEmpty)
        #expect(TitleSuggester.generate(prompt: "P", cli: cli) { _, _, _, _ in nil }.isEmpty)
    }
}
