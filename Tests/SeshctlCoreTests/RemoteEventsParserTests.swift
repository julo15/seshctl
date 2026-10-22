import Foundation
import Testing

@testable import SeshctlCore

@Suite("RemoteEventsParser")
struct RemoteEventsParserTests {

    // MARK: - Helpers

    /// Serialize a Swift dict to JSON `Data`. Force-tries because every test
    /// input here is hand-crafted from valid Swift literals.
    private func makeJSON(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [])
    }

    /// Build an `assistant` event with the given list of content blocks under
    /// `payload.message.content`. Mirrors the real captured shape from the
    /// cookie spike: `payload.type == "assistant"`, `payload.message.role ==
    /// "assistant"`, `payload.message.model`, etc.
    private func assistantEvent(
        sequenceNum: String = "1229",
        content: [[String: Any]]
    ) -> [String: Any] {
        [
            "event_id": UUID().uuidString,
            "event_type": "assistant",
            "sequence_num": sequenceNum,
            "created_at": "2026-05-21T12:30:00.000Z",
            "source": "worker",
            "payload": [
                "type": "assistant",
                "message": [
                    "id": "msg_xyz",
                    "role": "assistant",
                    "model": "claude-opus-4-7",
                    "content": content,
                ] as [String: Any],
                "session_id": "cse_abc",
                "request_id": "req_abc",
            ] as [String: Any],
        ]
    }

    private func userEvent(text: String = "Tal has it") -> [String: Any] {
        // Real user payload — `message.content` is a STRING, not an array.
        [
            "event_id": UUID().uuidString,
            "event_type": "user",
            "sequence_num": "1228",
            "created_at": "2026-05-21T12:29:00.000Z",
            "source": "client",
            "payload": [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": text,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    private func resultEvent() -> [String: Any] {
        [
            "event_id": UUID().uuidString,
            "event_type": "result",
            "sequence_num": "1230",
            "created_at": "2026-05-21T12:31:00.000Z",
            "source": "worker",
            "payload": [
                "type": "result",
                "duration_ms": 0,
                "result": "",
            ] as [String: Any],
        ]
    }

    // MARK: - Tests

    @Test("empty data returns nil")
    func emptyData() {
        #expect(RemoteEventsParser.extractLatestAssistantText(eventsResponseData: Data()) == nil)
    }

    @Test("non-JSON data returns nil")
    func nonJSON() {
        let data = Data("not json".utf8)
        #expect(RemoteEventsParser.extractLatestAssistantText(eventsResponseData: data) == nil)
    }

    @Test("top-level JSON array (not a dict) returns nil")
    func topLevelArray() {
        let data = makeJSON([] as [Any])
        #expect(RemoteEventsParser.extractLatestAssistantText(eventsResponseData: data) == nil)
    }

    @Test("dict without a `data` key returns nil")
    func missingDataKey() {
        let data = makeJSON(["next_cursor": "1182"])
        #expect(RemoteEventsParser.extractLatestAssistantText(eventsResponseData: data) == nil)
    }

    @Test("empty `data` array returns nil")
    func emptyDataArray() {
        let data = makeJSON(["data": [] as [Any]])
        #expect(RemoteEventsParser.extractLatestAssistantText(eventsResponseData: data) == nil)
    }

    @Test("only user and result events (no assistant) returns nil")
    func noAssistantEvents() {
        let body: [String: Any] = [
            "data": [
                resultEvent(),
                userEvent(text: "hi"),
            ] as [Any],
        ]
        #expect(RemoteEventsParser.extractLatestAssistantText(eventsResponseData: makeJSON(body)) == nil)
    }

    @Test("single assistant event with one text block returns that text")
    func singleAssistantText() {
        let body: [String: Any] = [
            "data": [
                assistantEvent(content: [
                    ["type": "text", "text": "Pushed. Commit `d2daa69`."],
                ]),
            ] as [Any],
        ]
        let result = RemoteEventsParser.extractLatestAssistantText(eventsResponseData: makeJSON(body))
        #expect(result == "Pushed. Commit `d2daa69`.")
    }

    @Test("multiple assistant events — FIRST in the array (newest) wins")
    func newestAssistantWins() {
        // The `data` array is server-sorted newest-first, so the first
        // assistant event we encounter is the latest one.
        let body: [String: Any] = [
            "data": [
                assistantEvent(sequenceNum: "1229", content: [
                    ["type": "text", "text": "Newest assistant reply."],
                ]),
                userEvent(text: "in between"),
                assistantEvent(sequenceNum: "1227", content: [
                    ["type": "text", "text": "Older assistant reply."],
                ]),
            ] as [Any],
        ]
        let result = RemoteEventsParser.extractLatestAssistantText(eventsResponseData: makeJSON(body))
        #expect(result == "Newest assistant reply.")
    }

    @Test("walks past a tool_use block to the first text block")
    func walksPastToolUse() {
        let body: [String: Any] = [
            "data": [
                assistantEvent(content: [
                    [
                        "type": "tool_use",
                        "id": "toolu_abc",
                        "name": "Read",
                        "input": ["file_path": "/tmp/x"] as [String: Any],
                    ] as [String: Any],
                    ["type": "text", "text": "Here is the file content."] as [String: Any],
                ]),
            ] as [Any],
        ]
        let result = RemoteEventsParser.extractLatestAssistantText(eventsResponseData: makeJSON(body))
        #expect(result == "Here is the file content.")
    }

    @Test("walks past a thinking block to the first text block")
    func walksPastThinking() {
        // Claude 4.x extended-thinking responses interleave `thinking` blocks
        // before the final `text` block. The parser should walk past them the
        // same way it walks past `tool_use`.
        let body: [String: Any] = [
            "data": [
                assistantEvent(content: [
                    [
                        "type": "thinking",
                        "thinking": "Let me reason through this step by step...",
                    ] as [String: Any],
                    ["type": "text", "text": "Here is my final answer."] as [String: Any],
                ]),
            ] as [Any],
        ]
        let result = RemoteEventsParser.extractLatestAssistantText(eventsResponseData: makeJSON(body))
        #expect(result == "Here is my final answer.")
    }

    @Test("assistant event with empty content array returns nil")
    func emptyContentArray() {
        let body: [String: Any] = [
            "data": [
                assistantEvent(content: []),
            ] as [Any],
        ]
        #expect(RemoteEventsParser.extractLatestAssistantText(eventsResponseData: makeJSON(body)) == nil)
    }

    @Test("assistant event with only tool_use blocks (no text) returns nil")
    func toolUseOnly() {
        let body: [String: Any] = [
            "data": [
                assistantEvent(content: [
                    [
                        "type": "tool_use",
                        "id": "toolu_abc",
                        "name": "Read",
                        "input": ["file_path": "/tmp/x"] as [String: Any],
                    ] as [String: Any],
                    [
                        "type": "tool_use",
                        "id": "toolu_def",
                        "name": "Bash",
                        "input": ["command": "ls"] as [String: Any],
                    ] as [String: Any],
                ]),
            ] as [Any],
        ]
        #expect(RemoteEventsParser.extractLatestAssistantText(eventsResponseData: makeJSON(body)) == nil)
    }

    @Test("assistant event with whitespace-only text returns nil")
    func whitespaceOnlyText() {
        let body: [String: Any] = [
            "data": [
                assistantEvent(content: [
                    ["type": "text", "text": "   \n\t  "],
                ]),
            ] as [Any],
        ]
        #expect(RemoteEventsParser.extractLatestAssistantText(eventsResponseData: makeJSON(body)) == nil)
    }

    @Test("trims leading and trailing whitespace from the returned text")
    func trimsWrappingWhitespace() {
        let body: [String: Any] = [
            "data": [
                assistantEvent(content: [
                    ["type": "text", "text": "\n\n  Pushed. Commit d2daa69.  \n  "],
                ]),
            ] as [Any],
        ]
        let result = RemoteEventsParser.extractLatestAssistantText(eventsResponseData: makeJSON(body))
        #expect(result == "Pushed. Commit d2daa69.")
    }

    @Test("preserves internal newlines (multi-line replies)")
    func preservesInternalNewlines() {
        let body: [String: Any] = [
            "data": [
                assistantEvent(content: [
                    ["type": "text", "text": "Line one.\nLine two.\n\nLine four."],
                ]),
            ] as [Any],
        ]
        let result = RemoteEventsParser.extractLatestAssistantText(eventsResponseData: makeJSON(body))
        #expect(result == "Line one.\nLine two.\n\nLine four.")
    }

    // MARK: - scanPage
    //
    // `scanPage` drives the fetcher's paging: a page of only system/control
    // events (the common case for remote-control sessions, which write a
    // `system/init` on every reconnect) must report `noAssistant` with the
    // cursor so the fetcher can step to older events.

    private func systemInit() -> [String: Any] {
        ["event_type": "system", "payload": ["type": "system", "subtype": "init"] as [String: Any]]
    }

    @Test("scanPage: page of only system events reports noAssistant with the string cursor")
    func scanPageSystemOnlyReportsCursor() {
        let body = makeJSON(["data": [systemInit(), systemInit()], "next_cursor": "5024"])
        #expect(RemoteEventsParser.scanPage(eventsResponseData: body) == .noAssistant(nextCursor: "5024"))
        #expect(RemoteEventsParser.extractLatestAssistantText(eventsResponseData: body) == nil)
    }

    @Test("scanPage: numeric next_cursor is accepted")
    func scanPageNumericCursor() {
        let body = makeJSON(["data": [systemInit()], "next_cursor": 297])
        #expect(RemoteEventsParser.scanPage(eventsResponseData: body) == .noAssistant(nextCursor: "297"))
    }

    @Test("scanPage: missing, null, or empty next_cursor means no older page")
    func scanPageNoCursor() {
        let missing = makeJSON(["data": [systemInit()]])
        let null = makeJSON(["data": [systemInit()], "next_cursor": NSNull()])
        let empty = makeJSON(["data": [systemInit()], "next_cursor": ""])
        #expect(RemoteEventsParser.scanPage(eventsResponseData: missing) == .noAssistant(nextCursor: nil))
        #expect(RemoteEventsParser.scanPage(eventsResponseData: null) == .noAssistant(nextCursor: nil))
        #expect(RemoteEventsParser.scanPage(eventsResponseData: empty) == .noAssistant(nextCursor: nil))
    }

    @Test("scanPage: assistant text behind system events is found")
    func scanPageFindsTextBehindSystemEvents() {
        let body = makeJSON([
            "data": [systemInit(), systemInit(), assistantEvent(content: [["type": "text", "text": " Done. "]])],
            "next_cursor": "100",
        ])
        #expect(RemoteEventsParser.scanPage(eventsResponseData: body) == .text("Done."))
    }

    @Test("scanPage: tool_use-only newest assistant turn stops paging")
    func scanPageToolUseOnlyStops() {
        let body = makeJSON([
            "data": [assistantEvent(content: [["type": "tool_use", "id": "t1", "name": "Bash", "input": [:] as [String: Any]]])],
            "next_cursor": "100",
        ])
        #expect(RemoteEventsParser.scanPage(eventsResponseData: body) == .assistantWithoutText)
    }

    @Test("scanPage: non-events body is malformed")
    func scanPageMalformed() {
        #expect(RemoteEventsParser.scanPage(eventsResponseData: Data("not json".utf8)) == .malformed)
        #expect(RemoteEventsParser.scanPage(eventsResponseData: makeJSON(["items": []])) == .malformed)
    }

    @Test("scanPage: an empty data array keeps paging")
    func scanPageEmptyDataKeepsPaging() {
        let body = makeJSON(["data": [] as [Any], "next_cursor": "12"])
        #expect(RemoteEventsParser.scanPage(eventsResponseData: body) == .noAssistant(nextCursor: "12"))
    }

    @Test("scanPage: an assistant event with a malformed message stops paging")
    func scanPageMalformedAssistantStops() {
        let body = makeJSON([
            "data": [systemInit(), ["event_type": "assistant", "payload": ["message": "not an object"] as [String: Any]]],
            "next_cursor": "12",
        ])
        #expect(RemoteEventsParser.scanPage(eventsResponseData: body) == .assistantWithoutText)
    }

    @Test("scanPage: a boolean next_cursor is not a cursor")
    func scanPageBooleanCursor() {
        let body = makeJSON(["data": [systemInit()], "next_cursor": true])
        #expect(RemoteEventsParser.scanPage(eventsResponseData: body) == .noAssistant(nextCursor: nil))
    }
}
