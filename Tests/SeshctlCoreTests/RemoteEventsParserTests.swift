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
}
