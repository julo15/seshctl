import Foundation

/// Suggests titles for a session on request (`t`), describing what it is
/// doing *now*. Claude Code's own `ai-title` is written once from the opening
/// prompt, so a long session that moved on keeps a title for its first task.
///
/// **Recency-biased material.** The prompt gets the user's last few requests
/// (short, and where intent lives), the latest assistant reply, and the
/// current title as background, and is told to title only the task the
/// session is on now. The tail of a long session is mostly "yes" and "merge",
/// so the last few turns alone would title whatever the final reply happened
/// to discuss.
///
/// **Three candidates per run.** About one generation in three comes back
/// garbled, and a run costs ~6s, so asking for three at once lets the user
/// skip a bad one without paying for a retry.
///
/// The output cleanup and CLI lookup come from @patoms's #69.
public enum TitleSuggester {

    /// How many recent user requests go into the prompt.
    static let recentAskCount = 10
    static let askCharacterLimit = 300
    static let replyCharacterLimit = 800
    static let candidateCount = 3
    static let maxWords = 8
    static let maxCharacters = 64

    // MARK: - Material

    /// The prompt for `turns`, or nil when the session has no user request to
    /// describe.
    public static func prompt(turns: [ConversationTurn], currentTitle: String?) -> String? {
        let asks = turns.compactMap { turn -> String? in
            guard case .userMessage(let text, _) = turn else { return nil }
            return condense(text, limit: askCharacterLimit)
        }.suffix(recentAskCount)
        guard !asks.isEmpty else { return nil }

        let reply = turns.reversed().lazy.compactMap { turn -> String? in
            guard case .assistantMessage(let text, _, _) = turn else { return nil }
            return condense(text, limit: replyCharacterLimit)
        }.first

        var sections = ["Recent user requests, oldest first:\n" + asks.map { "- \($0)" }.joined(separator: "\n")]
        if let currentTitle = condense(currentTitle ?? "", limit: 120) {
            sections.insert("Current title: \(currentTitle)", at: 0)
        }
        if let reply {
            sections.append("Latest assistant reply:\n\(reply)")
        }

        return """
        Below is the recent part of a coding session between a user and an AI agent. \
        The session may have moved through several tasks. Suggest \(candidateCount) \
        short titles for the task it is on NOW, judging mainly by the most recent \
        requests. Mention the original task only if it is still the focus.

        Rules:
        - One title per line, \(candidateCount) lines, nothing else.
        - At most \(maxWords) words each.
        - Describe the task, not the conversation. No "user asks" or "discussion of".
        - No numbering, quotation marks, trailing periods or markdown.

        ---
        \(sections.joined(separator: "\n\n"))
        """
    }

    /// Trim one turn to a prompt-sized excerpt, collapsing whitespace, or nil
    /// when it's empty.
    static func condense(_ text: String, limit: Int) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "\u{2026}"
    }

    // MARK: - Output

    /// Up to three distinct titles from a raw CLI response.
    public static func parseCandidates(_ raw: String) -> [String] {
        var seen = Set<String>()
        var titles: [String] = []
        for line in stripEscapeSequences(raw).split(separator: "\n") {
            guard let title = normalize(String(line)), seen.insert(title.lowercased()).inserted else { continue }
            titles.append(title)
            if titles.count == candidateCount { break }
        }
        return titles
    }

    /// Clean one line into a title, or nil when nothing usable is left.
    /// Models number, bullet, quote and punctuate titles despite being told
    /// not to, so each of those is stripped rather than trusted.
    static func normalize(_ line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Leading list markers: "1.", "2)", "-", "*", "•".
        if let marker = text.range(of: #"^(\d+[.)]|[-*•])\s*"#, options: .regularExpression) {
            text.removeSubrange(marker)
        }
        text = text.replacingOccurrences(of: "**", with: "")

        for quote in ["\"", "'", "\u{201C}", "\u{2018}", "`"] {
            let closing = ["\u{201C}": "\u{201D}", "\u{2018}": "\u{2019}"][quote] ?? quote
            if text.hasPrefix(quote), text.hasSuffix(closing), text.count > 1 {
                text = String(text.dropFirst().dropLast())
                break
            }
        }
        while let last = text.last, ".!,;:".contains(last) {
            text = String(text.dropLast())
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let words = text.split(separator: " ")
        if words.count > maxWords {
            text = words.prefix(maxWords).joined(separator: " ")
        }
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }
        return text
    }

    /// Remove ANSI CSI sequences and OSC strings, then other control
    /// characters. `claude -p` writes an OSC terminal-title escape to stdout
    /// alongside the answer, even with `--output-format text`.
    static func stripEscapeSequences(_ input: String) -> String {
        var output = String.UnicodeScalarView()
        let scalars = Array(input.unicodeScalars)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\u{1B}", index + 1 < scalars.count {
                let next = scalars[index + 1]
                if next == "]" {
                    // OSC: runs until BEL or ST (ESC backslash).
                    index += 2
                    while index < scalars.count {
                        if scalars[index] == "\u{07}" { index += 1; break }
                        if scalars[index] == "\u{1B}", index + 1 < scalars.count, scalars[index + 1] == "\\" {
                            index += 2
                            break
                        }
                        index += 1
                    }
                    continue
                }
                if next == "[" {
                    // CSI: parameter bytes then one final letter.
                    index += 2
                    while index < scalars.count, !CharacterSet.letters.contains(scalars[index]) {
                        index += 1
                    }
                    if index < scalars.count { index += 1 }
                    continue
                }
            }
            if scalar == "\n" || scalar.value >= 0x20 {
                output.append(scalar)
            }
            index += 1
        }
        return String(output)
    }

    // MARK: - CLI

    /// Where the `claude` binary usually lives. A GUI app inherits a minimal
    /// PATH without it, so the lookup can't go through `env`.
    static func claudeCLICandidates(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
    }

    public static func resolveClaudeCLI(home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> URL? {
        claudeCLICandidates(home: home)
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Arguments for a run that stays out of the user's history:
    /// `--setting-sources project`, run from an empty directory, loads no
    /// user settings, so seshctl's own hooks never record it as a session;
    /// `--no-session-persistence` keeps it out of `~/.claude/projects` and
    /// `/resume`.
    static func arguments(prompt: String) -> [String] {
        ["-p", "--model", "haiku", "--output-format", "text",
         "--setting-sources", "project", "--no-session-persistence", prompt]
    }

    /// Run the model and return its candidates, or an empty array on any
    /// failure (CLI missing, non-zero exit, timeout, unusable output).
    /// Blocks for several seconds, so call it off the main actor.
    public static func generate(
        prompt: String,
        cli: URL,
        timeout: TimeInterval = 45,
        runner: (String, [String], TimeInterval, URL?) -> ShellRunner.Result? = { path, args, timeout, directory in
            ShellRunner.run(path: path, args: args, timeout: timeout, currentDirectory: directory)
        }
    ) -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seshctl-titler", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let result = runner(cli.path, arguments(prompt: prompt), timeout, directory),
              result.status == 0
        else { return [] }
        return parseCandidates(result.stdout)
    }
}
