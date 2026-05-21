import Foundation

/// A single row in the rendered transcript. Either a single conversation turn
/// (passed through unchanged) or a collapsed block of contiguous assistant turns
/// whose only content was tool calls.
public enum DisplayItem: Sendable, Equatable, Identifiable {
    case userTurn(ConversationTurn)
    case assistantTurn(ConversationTurn)
    case awaySummaryTurn(ConversationTurn)
    case collapsedToolBlock(turns: [ConversationTurn], counts: BlockCounts)

    public var id: String {
        switch self {
        case .userTurn(let turn), .assistantTurn(let turn), .awaySummaryTurn(let turn):
            return turn.id
        case .collapsedToolBlock(let turns, _):
            return "block-\(turns.first?.id ?? "")"
        }
    }
}

/// Aggregate counts for a collapsed tool-call block.
public struct BlockCounts: Sendable, Equatable {
    public let toolCalls: Int
    public let messages: Int
    public let subagents: Int

    public init(toolCalls: Int, messages: Int, subagents: Int) {
        self.toolCalls = toolCalls
        self.messages = messages
        self.subagents = subagents
    }
}

/// Builds the renderable display item list from raw conversation turns.
public enum TranscriptDisplay {
    /// Walks `turns` and folds contiguous assistant turns whose `text` is empty
    /// (tool-call-only) into a single `.collapsedToolBlock`.
    /// - User turns and text-bearing assistant turns pass through unchanged.
    /// - The "Task" tool name counts as a subagent invocation.
    public static func build(_ turns: [ConversationTurn]) -> [DisplayItem] {
        var items: [DisplayItem] = []
        var pending: [ConversationTurn] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            var toolCalls = 0
            var subagents = 0
            for turn in pending {
                if case .assistantMessage(_, let calls, _) = turn {
                    toolCalls += calls.count
                    subagents += calls.filter { $0.toolName == "Task" }.count
                }
            }
            let counts = BlockCounts(
                toolCalls: toolCalls,
                messages: pending.count,
                subagents: subagents
            )
            items.append(.collapsedToolBlock(turns: pending, counts: counts))
            pending.removeAll()
        }

        for turn in turns {
            switch turn {
            case .userMessage:
                flushPending()
                items.append(.userTurn(turn))
            case .assistantMessage(let text, let toolCalls, _):
                if text.isEmpty && !toolCalls.isEmpty {
                    pending.append(turn)
                } else {
                    flushPending()
                    items.append(.assistantTurn(turn))
                }
            case .awaySummary:
                flushPending()
                items.append(.awaySummaryTurn(turn))
            }
        }
        flushPending()

        return items
    }
}
