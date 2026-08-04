import Foundation

/// Generates a frozen, chat-app-style thread title for a session.
///
/// The row already shows what a session *just said* (`TranscriptLatestAssistantScanner`).
/// That answers "what is happening now" and is useless as an identity — a
/// session's latest message is as likely to be "yes do that" as anything
/// describing the work. This answers the other question, "what is this
/// session", and is deliberately written once and left alone. Claude.ai and
/// ChatGPT name threads the same way.
///
/// **Two materials, two triggers.** Automatic titling runs once, off the
/// opening exchange, as soon as the first user→assistant round trip completes.
/// A user-requested retitle runs off the *latest* turns instead: the only
/// reason to ask for a new title is that the session drifted, and re-reading
/// the opening exchange would regenerate the same words.
///
/// **Availability.** Claude Code and Codex write transcripts we can parse.
/// Cursor and Gemini write none (see the compatibility table in the README),
/// so they can never be titled — callers get nil, not a placeholder.
public enum SessionTitler {

    /// Which part of the conversation to title from.
    public enum Material: Sendable {
        /// The first user prompt plus the first substantive assistant reply.
        /// Used for automatic titling — stable, and it's the exchange that
        /// states the task.
        case opening
        /// The most recent turns. Used when the user explicitly asks for a
        /// retitle, because the point of asking is that the opening exchange
        /// no longer describes the work.
        case latest
    }

    /// Longest title we accept. Beyond this the row truncates anyway, and a
    /// model that ignores the word limit usually overruns badly rather than
    /// slightly.
    static let maxWords = 8
    static let maxCharacters = 64

    /// How many recent turns `.latest` feeds to the model. Enough to capture a
    /// change of subject without paying for a whole transcript.
    static let latestTurnWindow = 6

    // MARK: - Readiness

    /// True when the transcript holds a complete user→assistant exchange, which
    /// is the earliest point a title can describe anything. Titling before the
    /// assistant has responded produces a title for a question, not for work.
    public static func hasCompleteFirstExchange(turns: [ConversationTurn]) -> Bool {
        guard let firstUserIndex = turns.firstIndex(where: {
            if case .userMessage = $0 { return true }
            return false
        }) else { return false }

        return turns[turns.index(after: firstUserIndex)...].contains { turn in
            guard case .assistantMessage(let text, _, _) = turn else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Prompt construction

    /// Build the excerpt handed to the model, or nil when there's nothing
    /// substantive to title.
    ///
    /// Both materials cap each turn's contribution — a single pasted stack
    /// trace shouldn't dominate the prompt, and the model only needs the gist.
    public static func excerpt(turns: [ConversationTurn], material: Material) -> String? {
        let selected: [ConversationTurn]
        switch material {
        case .opening:
            guard let firstUserIndex = turns.firstIndex(where: {
                if case .userMessage = $0 { return true }
                return false
            }) else { return nil }
            let assistantIndex = turns[turns.index(after: firstUserIndex)...].firstIndex { turn in
                guard case .assistantMessage(let text, _, _) = turn else { return false }
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            selected = [turns[firstUserIndex]] + (assistantIndex.map { [turns[$0]] } ?? [])
        case .latest:
            selected = Array(turns.suffix(latestTurnWindow))
        }

        let lines = selected.compactMap { turn -> String? in
            switch turn {
            case .userMessage(let text, _):
                guard let body = condense(text) else { return nil }
                return "User: \(body)"
            case .assistantMessage(let text, _, _):
                guard let body = condense(text) else { return nil }
                return "Assistant: \(body)"
            case .awaySummary:
                // A recap describes the session in the third person already —
                // feeding it back would title the recap, not the work.
                return nil
            }
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    /// Trim one turn to a prompt-sized excerpt, or nil when it's empty.
    static func condense(_ text: String, limit: Int = 600) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\u{2026}"
    }

    /// The instruction wrapped around the excerpt. Phrased to suppress the
    /// preamble and quoting habits that would otherwise need stripping.
    static func prompt(excerpt: String) -> String {
        """
        Below is the start of a coding session between a user and an AI agent. \
        Write a short title for it, in the style of a chat app naming a conversation.

        Rules:
        - At most \(maxWords) words.
        - Describe the task, not the conversation. No "user asks" or "discussion of".
        - No quotation marks, no trailing period, no markdown.
        - Reply with the title and nothing else.

        ---
        \(excerpt)
        """
    }

    // MARK: - Output normalization

    /// Clean a raw CLI response into a title, or nil when nothing usable came
    /// back.
    ///
    /// `claude -p` writes an OSC terminal-title escape to stdout alongside the
    /// answer (observed: `ESC]0;claude:0636` wrapping the text), so escape
    /// stripping is not optional even with `--output-format text`. Models also
    /// quote and punctuate titles despite being told not to.
    public static func normalize(_ raw: String) -> String? {
        var text = stripEscapeSequences(raw)

        // Take the first line with content — a stray preamble line would
        // otherwise become the title.
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        text = line

        // Strip matched surrounding quotes, then trailing sentence punctuation.
        for quote in ["\"", "'", "\u{201C}", "\u{2018}"] {
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

        // Enforce the limits the prompt asked for rather than trusting them.
        let words = text.split(separator: " ")
        if words.count > maxWords {
            text = words.prefix(maxWords).joined(separator: " ")
        }
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }

        return text.isEmpty ? nil : text
    }

    /// Remove ANSI CSI sequences and OSC strings, then any remaining control
    /// characters. Written by hand rather than with NSRegularExpression so
    /// this stays cheap enough to run on every generation.
    static func stripEscapeSequences(_ input: String) -> String {
        var output = String.UnicodeScalarView()
        var scalars = Array(input.unicodeScalars)
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
            // Keep newlines; drop other control characters.
            if scalar == "\n" || scalar.value >= 0x20 {
                output.append(scalar)
            }
            index += 1
        }

        return String(output)
    }

    // MARK: - CLI resolution

    /// Candidate locations for the `claude` binary, most authoritative first.
    ///
    /// A GUI app inherits a minimal PATH — `claude` is not on it — so the
    /// lookup can't rely on `env`. The first entry is where Claude Code's
    /// native installer puts its launcher; the rest cover Homebrew and manual
    /// installs. Mirrors `ExtensionInstaller.resolveEditorCLI`.
    static func claudeCLICandidates(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
    }

    /// First candidate that exists and is executable, or nil.
    public static func resolveClaudeCLI(
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> URL? {
        for path in claudeCLICandidates(home: home) where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Generation

    /// Run the model and return a normalized title.
    ///
    /// Returns nil on every failure path — CLI missing, non-zero exit, timeout,
    /// unusable output — so callers can treat "no title" uniformly. Failures
    /// are expected (offline, quota, CLI moved) and must never surface as an
    /// error to the user.
    ///
    /// The subprocess is marked with `InternalSession.environmentMarker`. It is
    /// an ordinary Claude Code run, so without the marker its `SessionStart`
    /// hook records a row of its own — a session whose whole content is the
    /// prompt asking to name another session.
    ///
    /// `runner` is injected so tests exercise the whole path without spawning a
    /// subprocess or spending tokens.
    public static func generate(
        excerpt: String,
        cli: URL,
        model: String = "haiku",
        timeout: TimeInterval = 45,
        runner: (String, [String], TimeInterval, [String: String]?) -> ShellRunner.Result? = ShellRunner.run
    ) -> String? {
        let result = runner(
            cli.path,
            ["-p", "--model", model, "--output-format", "text", prompt(excerpt: excerpt)],
            timeout,
            InternalSession.environmentMarker
        )
        guard let result, result.status == 0 else { return nil }
        return normalize(result.stdout)
    }
}
