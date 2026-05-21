import Foundation

/// Summary of a tool call made by the assistant.
public struct ToolCallSummary: Sendable, Equatable {
    public let toolName: String
    public let inputJSON: String?

    public init(toolName: String, inputJSON: String? = nil) {
        self.toolName = toolName
        self.inputJSON = inputJSON
    }

    /// One-line label suitable for display, derived from the tool name and (when available) its input.
    public var displayLabel: String {
        guard let inputJSON,
              let data = inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return toolName
        }

        switch toolName {
        case "Read":
            guard let path = dict["file_path"] as? String else { return toolName }
            return "Read \(path)"
        case "Write":
            guard let path = dict["file_path"] as? String else { return toolName }
            return "Write \(path)"
        case "Edit":
            guard let path = dict["file_path"] as? String else { return toolName }
            return "Edit \(path)"
        case "Bash":
            guard let command = dict["command"] as? String else { return toolName }
            return "Bash: \(truncate(command, 80))"
        case "Grep":
            guard let pattern = dict["pattern"] as? String else { return toolName }
            if let path = dict["path"] as? String {
                return "Grep \(pattern) in \(path)"
            }
            return "Grep \(pattern)"
        case "Glob":
            guard let pattern = dict["pattern"] as? String else { return toolName }
            return "Glob \(pattern)"
        case "Task":
            guard let description = dict["description"] as? String else { return toolName }
            return "Task: \(truncate(description, 80))"
        default:
            return toolName
        }
    }
}

private func truncate(_ string: String, _ limit: Int) -> String {
    guard string.count > limit else { return string }
    let prefixLength = max(0, limit - 1)
    return String(string.prefix(prefixLength)) + "\u{2026}"
}

/// A single turn in a conversation, ready for display.
public enum ConversationTurn: Sendable, Equatable, Identifiable {
    case userMessage(text: String, timestamp: Date)
    case assistantMessage(text: String, toolCalls: [ToolCallSummary], timestamp: Date)
    case awaySummary(text: String, timestamp: Date)

    public var id: String {
        switch self {
        case .userMessage(let text, let ts):
            return "user-\(ts.timeIntervalSince1970)-\(StableHash.djb2(text))"
        case .assistantMessage(let text, _, let ts):
            return "assistant-\(ts.timeIntervalSince1970)-\(StableHash.djb2(text))"
        case .awaySummary(let text, let ts):
            return "away-\(ts.timeIntervalSince1970)-\(StableHash.djb2(text))"
        }
    }

    public var timestamp: Date {
        switch self {
        case .userMessage(_, let ts): return ts
        case .assistantMessage(_, _, let ts): return ts
        case .awaySummary(_, let ts): return ts
        }
    }

}
