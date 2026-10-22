import Foundation
import SwiftUI
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

@Suite("AgentBadgeSpec.forAgent")
struct AgentBadgeSpecForAgentTests {

    @Test("claude → clay Claude mark")
    func claudeBadge() {
        let spec = AgentBadgeSpec.forAgent(.claude)
        #expect(spec.glyph == .claudeMark)
        #expect(spec.color == AgentBadgeSpec.claudeColor)
    }

    @Test("codex → indigo Codex mark")
    func codexBadge() {
        let spec = AgentBadgeSpec.forAgent(.codex)
        #expect(spec.glyph == .codexMark)
        #expect(spec.color == AgentBadgeSpec.codexColor)
    }

    @Test("gemini → blue G")
    func geminiBadge() {
        let spec = AgentBadgeSpec.forAgent(.gemini)
        #expect(spec.glyph == .letter("G"))
        #expect(spec.color == .blue)
    }

    /// Equality is part of the public surface — tests downstream of this
    /// (e.g. row-view callers) rely on `==` to assert the right badge was
    /// resolved.
    @Test("Equatable: identical specs compare equal; differing specs do not")
    func equatable() {
        #expect(AgentBadgeSpec.forAgent(.claude) == AgentBadgeSpec(glyph: .claudeMark, color: AgentBadgeSpec.claudeColor))
        #expect(AgentBadgeSpec.forAgent(.claude) != AgentBadgeSpec.forAgent(.codex))
        // Glyph case is part of identity: a `.letter("C")` is not equal
        // to `.claudeMark`, even at the same color.
        #expect(AgentBadgeSpec(glyph: .letter("C"), color: .orange) != AgentBadgeSpec(glyph: .claudeMark, color: .orange))
    }
}

@Suite("AgentBadgeSpec.forRemote")
struct AgentBadgeSpecForRemoteTests {

    /// Today every remote claude.ai session is a Claude session, so the
    /// resolver always returns the Claude badge regardless of the model
    /// string. The signature accepts `model` so a future codex/gemini-on-
    /// claude-ai split lands without an API change — that contract is
    /// pinned by these cases.
    @Test("claude-sonnet-4-6 → Claude badge")
    func sonnetReturnsClaude() {
        #expect(AgentBadgeSpec.forRemote(model: "claude-sonnet-4-6") == .forAgent(.claude))
    }

    @Test("claude-opus-4-7 → Claude badge")
    func opusReturnsClaude() {
        #expect(AgentBadgeSpec.forRemote(model: "claude-opus-4-7") == .forAgent(.claude))
    }

    @Test("empty model string → Claude badge (defensive default)")
    func emptyModelReturnsClaude() {
        #expect(AgentBadgeSpec.forRemote(model: "") == .forAgent(.claude))
    }

    @Test("unknown / future model identifier → Claude badge today")
    func unknownModelReturnsClaude() {
        #expect(AgentBadgeSpec.forRemote(model: "some-future-model-id") == .forAgent(.claude))
    }
}
