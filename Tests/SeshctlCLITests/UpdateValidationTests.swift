import Testing

@testable import seshctl_cli

@Suite("Update matcher validation")
struct UpdateValidationTests {
    @Test("PID and conversation ID are accepted together")
    func pidAndConversationId() throws {
        try Update.validateMatchers(pid: 123, conversationId: "session-123")
    }

    @Test("PID alone is accepted")
    func pidOnly() throws {
        try Update.validateMatchers(pid: 123, conversationId: nil)
    }

    @Test("Conversation ID alone is accepted")
    func conversationIdOnly() throws {
        try Update.validateMatchers(pid: nil, conversationId: "session-123")
    }

    @Test("Missing matcher is rejected")
    func missingMatcher() {
        #expect(throws: Error.self) {
            try Update.validateMatchers(pid: nil, conversationId: nil)
        }
    }
}
