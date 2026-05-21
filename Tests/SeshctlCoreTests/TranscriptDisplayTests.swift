import Foundation
import Testing

@testable import SeshctlCore

@Suite("TranscriptDisplay")
struct TranscriptDisplayTests {

    private func t(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + offset) }

    @Test("User turns pass through as .userTurn")
    func userPassthrough() {
        let turns: [ConversationTurn] = [
            .userMessage(text: "hi", timestamp: t(0))
        ]
        let items = TranscriptDisplay.build(turns)
        #expect(items.count == 1)
        if case .userTurn = items[0] { } else { Issue.record("expected .userTurn") }
    }

    @Test("Text-bearing assistant turn passes through as .assistantTurn")
    func assistantTextPassthrough() {
        let turns: [ConversationTurn] = [
            .assistantMessage(text: "hello", toolCalls: [], timestamp: t(0))
        ]
        let items = TranscriptDisplay.build(turns)
        #expect(items.count == 1)
        if case .assistantTurn = items[0] { } else { Issue.record("expected .assistantTurn") }
    }

    @Test("Contiguous tool-only assistant turns collapse into one block")
    func toolOnlyCollapse() {
        let turns: [ConversationTurn] = [
            .assistantMessage(text: "", toolCalls: [ToolCallSummary(toolName: "Read")], timestamp: t(0)),
            .assistantMessage(text: "", toolCalls: [ToolCallSummary(toolName: "Edit"), ToolCallSummary(toolName: "Bash")], timestamp: t(1)),
        ]
        let items = TranscriptDisplay.build(turns)
        #expect(items.count == 1)
        guard case .collapsedToolBlock(let blockTurns, let counts) = items[0] else {
            Issue.record("expected .collapsedToolBlock")
            return
        }
        #expect(blockTurns.count == 2)
        #expect(counts.toolCalls == 3)
        #expect(counts.messages == 2)
        #expect(counts.subagents == 0)
    }

    @Test("Mixed sequence: user, tool-only, tool-only, text, user")
    func mixedSequence() {
        let turns: [ConversationTurn] = [
            .userMessage(text: "go", timestamp: t(0)),
            .assistantMessage(text: "", toolCalls: [ToolCallSummary(toolName: "Read")], timestamp: t(1)),
            .assistantMessage(text: "", toolCalls: [ToolCallSummary(toolName: "Edit")], timestamp: t(2)),
            .assistantMessage(text: "done", toolCalls: [], timestamp: t(3)),
            .userMessage(text: "next", timestamp: t(4)),
        ]
        let items = TranscriptDisplay.build(turns)
        #expect(items.count == 4)
        if case .userTurn = items[0] {} else { Issue.record("items[0] should be .userTurn") }
        if case .collapsedToolBlock(_, let counts) = items[1] {
            #expect(counts.messages == 2)
            #expect(counts.toolCalls == 2)
        } else { Issue.record("items[1] should be .collapsedToolBlock") }
        if case .assistantTurn = items[2] {} else { Issue.record("items[2] should be .assistantTurn") }
        if case .userTurn = items[3] {} else { Issue.record("items[3] should be .userTurn") }
    }

    @Test("Subagent count tracks Task tool calls only")
    func subagentCount() {
        let turns: [ConversationTurn] = [
            .assistantMessage(text: "", toolCalls: [
                ToolCallSummary(toolName: "Task"),
                ToolCallSummary(toolName: "Read"),
                ToolCallSummary(toolName: "Task"),
            ], timestamp: t(0))
        ]
        let items = TranscriptDisplay.build(turns)
        guard case .collapsedToolBlock(_, let counts) = items[0] else {
            Issue.record("expected collapsed")
            return
        }
        #expect(counts.subagents == 2)
        #expect(counts.toolCalls == 3)
    }

    @Test("User turn between two tool-only runs flushes and starts a new block")
    func userBreaksBlocks() {
        let turns: [ConversationTurn] = [
            .assistantMessage(text: "", toolCalls: [ToolCallSummary(toolName: "Read")], timestamp: t(0)),
            .userMessage(text: "wait", timestamp: t(1)),
            .assistantMessage(text: "", toolCalls: [ToolCallSummary(toolName: "Edit")], timestamp: t(2)),
        ]
        let items = TranscriptDisplay.build(turns)
        #expect(items.count == 3)
        if case .collapsedToolBlock = items[0] {} else { Issue.record("items[0] should be block") }
        if case .userTurn = items[1] {} else { Issue.record("items[1] should be user") }
        if case .collapsedToolBlock = items[2] {} else { Issue.record("items[2] should be block") }
    }

    @Test("displayLabel handles known tools and falls back for unknown")
    func displayLabels() {
        let read = ToolCallSummary(toolName: "Read", inputJSON: "{\"file_path\":\"/tmp/foo.swift\"}")
        #expect(read.displayLabel == "Read /tmp/foo.swift")

        let bash = ToolCallSummary(toolName: "Bash", inputJSON: "{\"command\":\"git status\"}")
        #expect(bash.displayLabel == "Bash: git status")

        let task = ToolCallSummary(toolName: "Task", inputJSON: "{\"description\":\"investigate auth bug\"}")
        #expect(task.displayLabel == "Task: investigate auth bug")

        let unknown = ToolCallSummary(toolName: "MysteryTool", inputJSON: "{\"foo\":\"bar\"}")
        #expect(unknown.displayLabel == "MysteryTool")

        let nilInput = ToolCallSummary(toolName: "Read")
        #expect(nilInput.displayLabel == "Read")
    }

    @Test("displayLabel falls back to tool name on malformed JSON")
    func displayLabelMalformedJSON() {
        let bad = ToolCallSummary(toolName: "Read", inputJSON: "{not json")
        #expect(bad.displayLabel == "Read")
    }

    @Test("awaySummary turn passes through as its own display item")
    func awaySummaryTurnPassesThroughAsOwnItem() {
        let turn = ConversationTurn.awaySummary(text: "recap", timestamp: t(0))
        let items = TranscriptDisplay.build([turn])
        #expect(items.count == 1)
        guard case .awaySummaryTurn(let extracted) = items[0] else {
            Issue.record("expected .awaySummaryTurn")
            return
        }
        #expect(extracted == turn)
    }

    @Test("awaySummary flushes pending tool block and breaks the run")
    func awaySummaryFlushesPendingToolBlock() {
        let turns: [ConversationTurn] = [
            .assistantMessage(text: "", toolCalls: [ToolCallSummary(toolName: "Read")], timestamp: t(0)),
            .assistantMessage(text: "", toolCalls: [ToolCallSummary(toolName: "Edit")], timestamp: t(1)),
            .awaySummary(text: "recap", timestamp: t(2)),
            .assistantMessage(text: "", toolCalls: [ToolCallSummary(toolName: "Bash")], timestamp: t(3)),
            .assistantMessage(text: "", toolCalls: [ToolCallSummary(toolName: "Grep")], timestamp: t(4)),
        ]
        let items = TranscriptDisplay.build(turns)
        #expect(items.count == 3)
        if case .collapsedToolBlock(_, let counts) = items[0] {
            #expect(counts.messages == 2)
            #expect(counts.toolCalls == 2)
        } else {
            Issue.record("items[0] should be .collapsedToolBlock")
        }
        if case .awaySummaryTurn = items[1] {} else {
            Issue.record("items[1] should be .awaySummaryTurn")
        }
        if case .collapsedToolBlock(_, let counts) = items[2] {
            #expect(counts.messages == 2)
            #expect(counts.toolCalls == 2)
        } else {
            Issue.record("items[2] should be .collapsedToolBlock")
        }
    }
}
