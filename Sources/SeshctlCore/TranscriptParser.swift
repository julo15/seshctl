import Foundation

/// Parses Claude Code JSONL transcripts into conversation turns.
public enum TranscriptParser {

    /// Compute the transcript file URL for a session.
    /// If the session has a stored transcriptPath, use it directly.
    /// Otherwise falls back to Claude's computed path from conversationId.
    public static func transcriptURL(for session: Session) -> URL? {
        // If a transcript path is stored directly, use it
        if let path = session.transcriptPath {
            return URL(fileURLWithPath: path)
        }
        // Fall back to Claude's computed path
        guard let convId = session.conversationId else { return nil }
        return transcriptURL(conversationId: convId, directory: session.directory)
    }

    /// Compute the transcript file URL from raw fields (no Session required).
    public static func transcriptURL(conversationId: String, directory: String) -> URL {
        let encoded = encodePath(directory)
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/projects/\(encoded)/\(conversationId).jsonl")
    }

    /// Encode a directory path the way Claude Code does:
    /// `/Users/foo/bar` → `-Users-foo-bar`
    public static func encodePath(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
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

    /// Dispatch parsing based on the session's tool type.
    public static func parse(data: Data, tool: SessionTool) throws -> [ConversationTurn] {
        switch tool {
        case .claude:
            return try parse(data: data)
        case .codex:
            return try parseCodex(data: data)
        case .gemini, .cursor:
            return []
        }
    }

    /// Parse Codex JSONL transcript data into conversation turns.
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
                                  let text = block["text"] as? String else { return nil }
                            // Skip Codex system context injected into user messages
                            if text.hasPrefix("# AGENTS.md instructions")
                                || text.hasPrefix("<environment_context>")
                                || text.hasPrefix("<INSTRUCTIONS>")
                                || text.hasPrefix("<permissions instructions>")
                                || text.hasPrefix("<skills_instructions>") {
                                return nil
                            }
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
