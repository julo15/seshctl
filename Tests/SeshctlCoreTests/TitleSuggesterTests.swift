import Foundation
import Testing

@testable import SeshctlCore

@Suite("TitleSuggester")
struct TitleSuggesterTests {
    private let t0 = Date(timeIntervalSince1970: 1000)

    private func ask(_ text: String) -> ConversationTurn { .userMessage(text: text, timestamp: t0) }
    private func reply(_ text: String) -> ConversationTurn { .assistantMessage(text: text, toolCalls: [], timestamp: t0) }

    @Test("The prompt carries the last 10 asks and the last 3 replies")
    func promptIsRecencyBiased() throws {
        let turns = (1...12).flatMap { [ask("ask \($0)"), reply("reply \($0)")] }

        let prompt = try #require(TitleSuggester.prompt(turns: turns))

        #expect(!prompt.contains("- ask 2\n"), "older asks fall out of the window")
        #expect(prompt.contains("- ask 3\n"))
        #expect(prompt.contains("- ask 12"))
        #expect(!prompt.contains("- reply 9\n"))
        #expect(prompt.contains("- reply 10\n- reply 11\n- reply 12"))
        #expect(prompt.contains("task it is on NOW"))
    }

    @Test("Messages the user didn't type stay out of the window")
    func skipsNonTypedMessages() throws {
        let turns = [
            ask("real request one"),
            ask("Base directory for this skill: /Users/x/.claude/skills/review-gate\n\nRun a review"),
            ask("<task-notification> <task-id>abc</task-id>"),
            ask("[Image: source: /tmp/images/1.png]"),
            ask("[Image #1] aren't we done with this?"),
        ]

        let prompt = try #require(TitleSuggester.prompt(turns: turns))

        #expect(prompt.contains("- real request one\n- aren't we done with this?"))
        #expect(!prompt.contains("skill"))
        #expect(!prompt.contains("task-id"))
        #expect(!prompt.contains("Image"))
    }

    @Test("Long turns are trimmed and whitespace collapsed")
    func longTurnsAreTrimmed() throws {
        let long = String(repeating: "word ", count: 200)
        let prompt = try #require(TitleSuggester.prompt(turns: [ask("multi\n\nline   ask"), reply(long)]))

        #expect(prompt.contains("- multi line ask"))
        #expect(prompt.contains("\u{2026}"))
    }

    @Test("No user request, no prompt")
    func noAskNoPrompt() {
        #expect(TitleSuggester.prompt(turns: [reply("hello")]) == nil)
        #expect(TitleSuggester.prompt(turns: [ask("   ")]) == nil)
        #expect(TitleSuggester.prompt(turns: [ask("<task-notification>x")]) == nil)
    }

    @Test("The title is the first usable line, cleaned up")
    func parsesTitle() {
        #expect(TitleSuggester.parseTitle("\u{1B}]0;claude\u{07}1. \"Right-align the model pill\".\nSecond idea") == "Right-align the model pill")
        #expect(TitleSuggester.parseTitle("\n- **Fix icon slot width**!") == "Fix icon slot width")
        #expect(TitleSuggester.parseTitle("\u{201C}Tighten chevron spacing.\u{201D}") == "Tighten chevron spacing", "punctuation inside the quotes too")
        #expect(TitleSuggester.parseTitle("  \n\"\"") == nil)
    }

    @Test("Numbers and bold that aren't list markers survive")
    func keepsLeadingNumbersAndBold() {
        #expect(TitleSuggester.parseTitle("3.5 Sonnet upgrade") == "3.5 Sonnet upgrade")
        #expect(TitleSuggester.parseTitle("**Fix login**") == "Fix login")
        #expect(TitleSuggester.parseTitle("2) Fix login") == "Fix login")
    }

    @Test("A CSI sequence ending in ~ doesn't eat the title's first letter")
    func stripsTildeTerminatedCSI() {
        #expect(TitleSuggester.parseTitle("\u{1B}[200~Fix login") == "Fix login")
    }

    @Test("Overlong titles are cut to eight words")
    func capsWords() {
        #expect(TitleSuggester.parseTitle("one two three four five six seven eight nine ten") == "one two three four five six seven eight")
    }

    @Test("generate runs Haiku with no tools, user settings or persistence, from a fresh directory")
    func generateArguments() throws {
        var captured: (args: [String], directory: URL?)?
        var existedDuringRun = false
        let title = TitleSuggester.generate(prompt: "P", cli: URL(fileURLWithPath: "/bin/claude")) { _, args, _, directory in
            captured = (args, directory)
            existedDuringRun = directory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return ShellRunner.Result(stdout: "Model pill", stderr: "", status: 0)
        }

        #expect(title == .success("Model pill"))
        let args = captured?.args ?? []
        #expect(args.contains("--no-session-persistence"))
        #expect(args.contains("--setting-sources") && args.contains("project"))
        #expect(args.contains("--strict-mcp-config"))
        let tools = try #require(args.firstIndex(of: "--tools"))
        #expect(args[tools + 1] == "", "no tools at all")
        #expect(args.contains("haiku"))
        #expect(args.last == "P")
        let directory = try #require(captured?.directory)
        #expect(existedDuringRun)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "removed after the run")
    }

    @Test("Each run gets its own directory")
    func generateUsesFreshDirectories() {
        var directories: [URL] = []
        for _ in 0..<2 {
            _ = TitleSuggester.generate(prompt: "P", cli: URL(fileURLWithPath: "/bin/claude")) { _, _, _, directory in
                directory.map { directories.append($0) }
                return ShellRunner.Result(stdout: "T", stderr: "", status: 0)
            }
        }
        #expect(directories.count == 2 && directories[0] != directories[1])
    }

    @Test("A failed run gives no title")
    func generateFailure() {
        let cli = URL(fileURLWithPath: "/bin/claude")
        #expect(TitleSuggester.generate(prompt: "P", cli: cli) { _, _, _, _ in
            ShellRunner.Result(stdout: "A", stderr: "quota", status: 1)
        } == .failure(.runFailed))
        #expect(TitleSuggester.generate(prompt: "P", cli: cli) { _, _, _, _ in nil } == .failure(.runFailed))
        #expect(TitleSuggester.generate(prompt: "P", cli: cli) { _, _, _, _ in
            ShellRunner.Result(stdout: "\"\"", stderr: "", status: 0)
        } == .failure(.runFailed), "nothing usable in the output")
    }

    @Test("resolveClaudeCLI takes the user's own install first, and skips files it can't run")
    func resolvesCLI() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        #expect(TitleSuggester.resolveClaudeCLI(home: home.path)?.path == claude.path)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: claude.path)
        #expect(TitleSuggester.resolveClaudeCLI(home: home.path)?.path != claude.path)
    }

    @Test("ShellRunner runs in the given directory with an empty stdin")
    func shellRunnerDirectoryAndStdin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pwd = try #require(ShellRunner.run(path: "/bin/pwd", args: ["-P"], timeout: 5, currentDirectory: directory))
        // Resolve both sides alike: pwd -P prints /private/var/…, and
        // resolvingSymlinksInPath() drops the /private prefix.
        #expect(URL(fileURLWithPath: pwd.stdout).resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)

        let cat = try #require(ShellRunner.run(path: "/bin/cat", args: [], timeout: 5))
        #expect(cat.status == 0 && cat.stdout.isEmpty, "cat sees end of input at once instead of waiting")
    }
}
