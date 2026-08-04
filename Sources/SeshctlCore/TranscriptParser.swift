import Foundation

/// Parses Claude Code JSONL transcripts into conversation turns.
public enum TranscriptParser {

    /// `~/.claude/projects` — the root under which Claude Code writes per-cwd
    /// transcript dirs. Default for all path-resolution functions below.
    /// Overridable for tests.
    public static let defaultProjectsRoot: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    /// Compute the transcript file URL from raw fields (no Session required).
    public static func transcriptURL(conversationId: String, directory: String) -> URL {
        transcriptURL(conversationId: conversationId, directory: directory, projectsRoot: defaultProjectsRoot)
    }

    /// Same as above but with an overridable `projectsRoot` for tests and
    /// resolver internals.
    public static func transcriptURL(conversationId: String, directory: String, projectsRoot: URL) -> URL {
        projectsRoot.appendingPathComponent("\(encodePath(directory))/\(conversationId).jsonl")
    }

    /// Encode a directory path the way Claude Code does. Empirically Claude
    /// replaces any character outside `[A-Za-z0-9_-]` with `-`, so e.g.
    /// `/Users/julianlo/Documents/me/seshctl/.claude/worktrees/julo+row` →
    /// `-Users-julianlo-Documents-me-seshctl--claude-worktrees-julo-row`. The
    /// original `/` → `-` transform missed `.` (the `.claude` segment) and
    /// `+` (worktree branch names), which is what made the resolver's leg-B
    /// probe miss the worktree case before this was widened.
    public static func encodePath(_ path: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(path.count)
        for scalar in path.unicodeScalars {
            if Self.unreservedPathScalars.contains(scalar) {
                encoded.unicodeScalars.append(scalar)
            } else {
                encoded.append("-")
            }
        }
        return encoded
    }

    private static let unreservedPathScalars: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        set.insert(charactersIn: "0123456789")
        set.insert(charactersIn: "_-")
        return set
    }()

    /// Resolve a session's transcript to a file that actually exists on disk.
    ///
    /// Three-step probe:
    /// 1. `session.transcriptPath` if it exists (the value the Claude hook
    ///    forwarded most recently),
    /// 2. else the computed `<projectsRoot>/<encoded dir>/<convId>.jsonl`,
    /// 3. else any `<projectsRoot>/<X>/<convId>.jsonl` that exists.
    ///
    /// Leg 3 exists because Claude Code names the transcript file from the
    /// cwd at session start and never moves it, but the hook payload's
    /// `transcript_path` is re-derived from the *current* cwd on every
    /// event. So whenever the user `cd`s elsewhere mid-session (e.g. into
    /// `.claude/worktrees/<name>`), the stored path points at a directory
    /// that doesn't exist. Even with the widened `encodePath` (which catches
    /// most `cd` cases via leg 2), the glob is the belt-and-suspenders for
    /// any future encoding-rule drift on Claude's side. Conversation ids
    /// are UUIDs, so a single filename matches at most one path under
    /// `projectsRoot`.
    public static func resolveExistingTranscript(
        for session: Session,
        projectsRoot: URL = defaultProjectsRoot
    ) -> URL? {
        if let path = session.transcriptPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let convId = session.conversationId else { return nil }
        return resolveExistingTranscript(
            conversationId: convId,
            directory: session.directory,
            projectsRoot: projectsRoot
        )
    }

    /// Resolve a transcript from raw conversation-id + directory fields.
    /// Used by the recall-result branch in the detail view (no `Session`
    /// available) and by the `for session:` overload after leg 1. Runs
    /// legs 2 and 3 only — there's no stored `transcriptPath` to consult.
    public static func resolveExistingTranscript(
        conversationId: String,
        directory: String,
        projectsRoot: URL = defaultProjectsRoot
    ) -> URL? {
        let fm = FileManager.default
        let computed = transcriptURL(conversationId: conversationId, directory: directory, projectsRoot: projectsRoot)
        if fm.fileExists(atPath: computed.path) {
            return computed
        }
        return findTranscript(conversationId: conversationId, in: projectsRoot)
    }

    /// Walk `projectsRoot` one level deep looking for `<conversationId>.jsonl`.
    /// The `projectsRoot` parameter is overridable for testing only.
    public static func findTranscript(
        conversationId: String,
        in projectsRoot: URL = defaultProjectsRoot
    ) -> URL? {
        let fm = FileManager.default
        let filename = "\(conversationId).jsonl"
        guard let entries = try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for entry in entries {
            let candidate = entry.appendingPathComponent(filename)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Parse a JSONL transcript file into conversation turns.
    public static func parse(url: URL) throws -> [ConversationTurn] {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    /// Parse JSONL data into conversation turns.
    public static func parse(data: Data) throws -> [ConversationTurn] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }

        // First pass: collect raw entries, grouping assistant messages by message.id
        var assistantGroups: [(id: String, timestamp: Date, contentBlocks: [[String: Any]])] = []
        var assistantIndex: [String: Int] = [:]  // message.id → index in assistantGroups
        var userTurns: [(text: String, timestamp: Date)] = []
        var awaySummaryTurns: [(text: String, timestamp: Date)] = []

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            let timestamp = parseTimestamp(json["timestamp"], formatter: isoFormatter) ?? Date.distantPast

            // Note: the row preview uses TranscriptAwaySummaryScanner which suppresses
            // recaps once the conversation resumes (stale). The detail view shows every
            // recap in chronological order — historical context, not "current state".
            if type == "system", json["subtype"] as? String == "away_summary" {
                guard let content = json["content"] as? String else { continue }
                let stripped = TranscriptAwaySummaryScanner.stripRecapHint(content)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if stripped.isEmpty { continue }
                awaySummaryTurns.append((text: stripped, timestamp: timestamp))
                continue
            } else if type == "user" || type == "assistant" {
                guard let message = json["message"] as? [String: Any] else { continue }

                if type == "user" {
                    if let text = extractUserText(from: message) {
                        userTurns.append((text: text, timestamp: timestamp))
                    }
                } else if type == "assistant" {
                    guard let messageId = message["id"] as? String,
                          let contentArray = message["content"] as? [[String: Any]] else { continue }

                    if let idx = assistantIndex[messageId] {
                        assistantGroups[idx].contentBlocks.append(contentsOf: contentArray)
                        // Use latest timestamp
                        assistantGroups[idx].timestamp = timestamp
                    } else {
                        assistantIndex[messageId] = assistantGroups.count
                        assistantGroups.append((id: messageId, timestamp: timestamp, contentBlocks: contentArray))
                    }
                }
            } else {
                continue
            }
        }

        // Second pass: convert grouped data into ConversationTurn
        var turns: [ConversationTurn] = []

        // Collect all turns with timestamps for sorting
        for user in userTurns {
            turns.append(.userMessage(text: user.text, timestamp: user.timestamp))
        }

        for group in assistantGroups {
            let (text, toolCalls) = extractAssistantContent(from: group.contentBlocks)
            // Skip empty assistant turns (e.g., thinking-only)
            if text.isEmpty && toolCalls.isEmpty { continue }
            turns.append(.assistantMessage(text: text, toolCalls: toolCalls, timestamp: group.timestamp))
        }

        for summary in awaySummaryTurns {
            turns.append(.awaySummary(text: summary.text, timestamp: summary.timestamp))
        }

        // Sort chronologically
        turns.sort { $0.timestamp < $1.timestamp }
        return turns
    }

    /// Whether `parse(data:tool:)` can return turns for this tool at all.
    ///
    /// The inverse of the `.gemini, .cursor` arm below. Callers that walk every
    /// session looking for transcript-derived signals use this to skip the ones
    /// that write nothing, instead of each maintaining its own tool list that
    /// silently rots when a tool is added.
    public static func parsesTranscripts(_ tool: SessionTool) -> Bool {
        switch tool {
        case .claude, .codex, .pi: return true
        case .gemini, .cursor: return false
        }
    }

    /// Dispatch parsing based on the session's tool type.
    public static func parse(data: Data, tool: SessionTool) throws -> [ConversationTurn] {
        switch tool {
        case .claude:
            return try parse(data: data)
        case .codex:
            return try parseCodex(data: data)
        case .pi:
            return try parsePi(data: data)
        case .gemini, .cursor:
            return []
        }
    }

    /// Parse Codex JSONL transcript data into conversation turns.
    ///
    /// Codex writes `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`:
    /// a `session_meta` header followed by `response_item` envelopes wrapping
    /// `input_text` / `output_text` / `tool_use` blocks, plus `event_msg`
    /// records.
    ///
    /// **Don't confuse this with Pi.** Both tools can share one home directory
    /// — with `CODEX_HOME` pointed at `~/.agents`, Pi's session tree sits
    /// beside Codex's `rollout-*` files in the same `sessions/` folder, in a
    /// completely different format. `parsePi` handles that one. Telling them
    /// apart by directory or by a `provider` field fails: Pi records
    /// `provider: "openai-codex"` when Codex is its *model provider*, which
    /// says nothing about which tool wrote the file. Go by path shape
    /// (`rollout-*` vs `--<cwd>--/<ts>_<id>`) or record types.
    public static func parseCodex(data: Data) throws -> [ConversationTurn] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var turns: [ConversationTurn] = []

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            let timestamp = parseTimestamp(json["timestamp"], formatter: isoFormatter) ?? Date.distantPast

            if type == "response_item",
               let payload = json["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String {

                if payloadType == "message",
                   let role = payload["role"] as? String,
                   let content = payload["content"] as? [[String: Any]] {

                    if role == "user" {
                        let textParts = content.compactMap { block -> String? in
                            guard (block["type"] as? String) == "input_text",
                                  let text = block["text"] as? String,
                                  !isInjectedAgentContext(text) else { return nil }
                            return text
                        }
                        let joined = textParts.joined(separator: "\n")
                        if !joined.isEmpty {
                            turns.append(.userMessage(text: joined, timestamp: timestamp))
                        }
                    } else if role == "assistant" {
                        var textParts: [String] = []
                        var toolCalls: [ToolCallSummary] = []
                        for block in content {
                            let blockType = block["type"] as? String ?? ""
                            if blockType == "output_text", let t = block["text"] as? String, !t.isEmpty {
                                textParts.append(t)
                            } else if blockType == "tool_use" || blockType == "tool_call" {
                                if let name = block["name"] as? String {
                                    let json = serializeToolInput(block["input"]) ?? serializeToolInput(block["arguments"])
                                    toolCalls.append(ToolCallSummary(toolName: name, inputJSON: json))
                                }
                            }
                        }
                        let text = textParts.joined(separator: "\n")
                        if !text.isEmpty || !toolCalls.isEmpty {
                            turns.append(.assistantMessage(text: text, toolCalls: toolCalls, timestamp: timestamp))
                        }
                    }
                } else if payloadType == "function_call" {
                    let name = payload["name"] as? String ?? "tool"
                    let json = serializeToolInput(payload["input"]) ?? serializeToolInput(payload["arguments"])
                    turns.append(.assistantMessage(
                        text: "",
                        toolCalls: [ToolCallSummary(toolName: name, inputJSON: json)],
                        timestamp: timestamp
                    ))
                }
            } else if type == "event_msg",
                      let payload = json["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String,
                      payloadType.contains("tool") {
                let name = payload["tool_name"] as? String ?? payloadType
                let inputJSON = serializeToolInput(payload["input"]) ?? serializeToolInput(payload["arguments"])
                turns.append(.assistantMessage(
                    text: "",
                    toolCalls: [ToolCallSummary(toolName: name, inputJSON: inputJSON)],
                    timestamp: timestamp
                ))
            }
        }

        turns.sort { $0.timestamp < $1.timestamp }
        return turns
    }

    /// Parse a Pi JSONL transcript into conversation turns.
    ///
    /// Pi writes `<home>/sessions/--<encoded-cwd>--/<ts>_<uuid>.jsonl`, where
    /// `<home>` is `~/.agents` on current versions and `~/.pi/agent` on older
    /// ones. The format is a `{"type":"session","version":3,…}` header followed
    /// by `{"type":"message","message":{"role":…,"content":[…]}}` records, with
    /// `model_change` / `thinking_level_change` interleaved. Roles are
    /// `user` / `assistant` / `toolResult`; content blocks are `text`,
    /// `thinking`, and `toolCall`.
    ///
    /// Shares `isInjectedAgentContext` with `parseCodex` but nothing else —
    /// see that function's note on why the two must not be conflated.
    public static func parsePi(data: Data) throws -> [ConversationTurn] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var turns: [ConversationTurn] = []
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "message",
                  let message = json["message"] as? [String: Any]
            else { continue }

            let timestamp = parseTimestamp(json["timestamp"], formatter: isoFormatter) ?? Date.distantPast
            if let turn = parsePiMessage(message, timestamp: timestamp) {
                turns.append(turn)
            }
        }

        turns.sort { $0.timestamp < $1.timestamp }
        return turns
    }

    /// Convert one Pi `message` record into a turn, or nil when it carries
    /// nothing displayable.
    ///
    /// - `user` — `text` blocks, minus the context Codex injects into the
    ///   user role (see `isInjectedAgentContext`).
    /// - `assistant` — `text` blocks become the body, `toolCall` blocks become
    ///   `ToolCallSummary`. `thinking` blocks are dropped: the detail view has
    ///   no reasoning affordance, and reasoning text would otherwise dominate
    ///   the turn (72 thinking blocks against 28 text blocks in a sampled
    ///   transcript).
    /// - `toolResult` — dropped, matching the legacy path, which likewise
    ///   emits no turn for tool output.
    static func parsePiMessage(_ message: [String: Any], timestamp: Date) -> ConversationTurn? {
        guard let role = message["role"] as? String,
              let content = message["content"] as? [[String: Any]] else { return nil }

        switch role {
        case "user":
            let textParts = content.compactMap { block -> String? in
                guard (block["type"] as? String) == "text",
                      let text = block["text"] as? String,
                      !isInjectedAgentContext(text) else { return nil }
                return text
            }
            let joined = textParts.joined(separator: "\n")
            return joined.isEmpty ? nil : .userMessage(text: joined, timestamp: timestamp)

        case "assistant":
            var textParts: [String] = []
            var toolCalls: [ToolCallSummary] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        textParts.append(text)
                    }
                case "toolCall":
                    if let name = block["name"] as? String {
                        toolCalls.append(ToolCallSummary(
                            toolName: name,
                            inputJSON: serializeToolInput(block["arguments"])
                        ))
                    }
                default:
                    break
                }
            }
            let text = textParts.joined(separator: "\n")
            guard !text.isEmpty || !toolCalls.isEmpty else { return nil }
            return .assistantMessage(text: text, toolCalls: toolCalls, timestamp: timestamp)

        default:
            return nil
        }
    }

    /// True when a user-role text block is context the agent injected rather
    /// than something the human typed.
    ///
    /// Shared by `parseCodex` and `parsePi` — the two formats differ, but both
    /// tools splice the same kinds of preamble into the user role. The
    /// `<skill …>` entries and the trailing "References are relative to …"
    /// line come from Pi; the rest predate it.
    static func isInjectedAgentContext(_ text: String) -> Bool {
        let prefixes = [
            "# AGENTS.md instructions",
            "<environment_context>",
            "<INSTRUCTIONS>",
            "<permissions instructions>",
            "<skills_instructions>",
            "<skill name=",
            "References are relative to ",
        ]
        return prefixes.contains { text.hasPrefix($0) }
    }

    // MARK: - Private helpers

    private static func parseTimestamp(_ value: Any?, formatter: ISO8601DateFormatter) -> Date? {
        guard let str = value as? String else { return nil }
        if let date = formatter.date(from: str) { return date }
        // Fallback: try without fractional seconds (ISO8601DateFormatter requires
        // fractional seconds to be present when .withFractionalSeconds is set).
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: str)
    }

    /// Extract displayable text from a user message.
    /// Returns nil for tool_result messages (API plumbing).
    private static func extractUserText(from message: [String: Any]) -> String? {
        let content = message["content"]

        // String content = direct user prompt
        if let text = content as? String {
            let stripped = stripInternalTags(text)
            return stripped.isEmpty ? nil : stripped
        }

        // Array content — check if it's all tool_results (skip) or has text
        if let blocks = content as? [[String: Any]] {
            let textBlocks = blocks.filter { ($0["type"] as? String) == "text" }
            if textBlocks.isEmpty { return nil }  // All tool_result — skip
            let text = textBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let stripped = stripInternalTags(text)
            return stripped.isEmpty ? nil : stripped
        }

        return nil
    }

    /// Remove Claude Code internal tags and their content from user-visible text.
    static func stripInternalTags(_ text: String) -> String {
        let tags = [
            "system-reminder",
            "local-command-stdout",
            "local-command-stderr",
            "user-prompt-submit-hook",
            "task-notification",
        ]
        let pattern = "<(\(tags.joined(separator: "|")))>[\\s\\S]*?</\\1>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let result = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract text and tool calls from merged assistant content blocks.
    private static func extractAssistantContent(from blocks: [[String: Any]]) -> (String, [ToolCallSummary]) {
        var textParts: [String] = []
        var toolCalls: [ToolCallSummary] = []

        for block in blocks {
            guard let blockType = block["type"] as? String else { continue }
            switch blockType {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    textParts.append(text)
                }
            case "tool_use":
                if let name = block["name"] as? String {
                    let json = serializeToolInput(block["input"]) ?? serializeToolInput(block["arguments"])
                    toolCalls.append(ToolCallSummary(toolName: name, inputJSON: json))
                }
            default:
                // Skip thinking, etc.
                break
            }
        }

        return (textParts.joined(separator: "\n"), toolCalls)
    }

    /// Serialize a tool_use block's input/arguments field to a JSON string.
    /// Accepts either a dict (encoded via JSONSerialization) or a pre-encoded JSON string.
    private static func serializeToolInput(_ value: Any?) -> String? {
        if let dict = value as? [String: Any] {
            guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        if let str = value as? String { return str }
        return nil
    }
}
