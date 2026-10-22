import SwiftUI
import SeshctlCore

/// Pure data describing the agent-kind corner badge that overlays the host
/// app icon on each row. Composed by `BadgedIcon` (see
/// `BadgedIcon.swift`) — this struct knows nothing about rendering.
///
/// The visual language is a glyph on a solid colored circle. The default
/// glyph is a typographic monogram (one capital letter); a case may opt
/// into a vector mark instead. The glyph is the disambiguator for
/// color-blind users; the color is the at-a-glance signal for everyone
/// else.
///
/// Adding a new agent: extend `SessionTool` first, then add a case to
/// `forAgent(_:)` below. Compiler exhaustiveness will flag every other
/// switch on `SessionTool` that needs updating. This is the canonical
/// registration point for new agent badges — see plan
/// `2026-04-29-1730-row-ui-gmail-redesign.md` (Unit 3).
public struct AgentBadgeSpec: Equatable {
    /// Glyph drawn inside the badge circle. `letter(_)` is the default
    /// typographic monogram; `claudeMark` and `codexMark` opt into the
    /// vector marks rendered by `ClaudeLogoShape` and `CodexLogoShape`.
    /// Adding a new vector glyph
    /// = adding a new case here, which forces every renderer's switch
    /// to be updated.
    public enum Glyph: Equatable {
        /// One-character monogram (e.g. `"X"`, `"G"`).
        case letter(String)
        /// Claude AI mark, rendered as a vector path.
        case claudeMark
        /// Codex mark, rendered as a vector path.
        case codexMark
    }

    public let glyph: Glyph
    /// Fill of the badge circle.
    public let color: Color
    /// Color the glyph is drawn in. White on every badge except Codex,
    /// whose solid mark only reads at 14pt as a colored shape on white.
    public let glyphColor: Color

    public init(glyph: Glyph, color: Color, glyphColor: Color = .white) {
        self.glyph = glyph
        self.color = color
        self.glyphColor = glyphColor
    }
}

extension AgentBadgeSpec {
    /// Claude's brand clay (#D97757). System orange read as a generic
    /// warning color rather than Claude.
    static let claudeColor = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

    /// Indigo from the middle of the Codex icon's blue-violet gradient
    /// (#7A9DFF → #3941FF). Used for the mark itself, on a white disc like
    /// the Codex app icon: a white mark on an indigo disc merged with the
    /// badge's white ring at row size and hid the `>_`.
    static let codexColor = Color(red: 0x4F / 255, green: 0x5B / 255, blue: 0xFF / 255)

    /// Resolves the badge spec for a local session's agent kind. Today's
    /// mapping: Claude → clay Claude mark, Codex → indigo mark on white,
    /// Gemini → blue `G`, Cursor → purple `C`.
    public static func forAgent(_ tool: SessionTool) -> AgentBadgeSpec {
        switch tool {
        case .claude: return AgentBadgeSpec(glyph: .claudeMark, color: claudeColor)
        case .codex:  return AgentBadgeSpec(glyph: .codexMark, color: .white, glyphColor: codexColor)
        case .gemini: return AgentBadgeSpec(glyph: .letter("G"), color: .blue)
        case .cursor: return AgentBadgeSpec(glyph: .letter("C"), color: .purple)
        }
    }

    /// Resolves the badge spec for a remote claude.ai session. The `model`
    /// parameter is reserved for a future split (e.g. routing a hypothetical
    /// codex-on-claude-ai or gemini-on-claude-ai session to a non-Claude
    /// badge); today every claude.ai session is a Claude session, so this
    /// always returns the Claude badge regardless of the input.
    ///
    /// Callers should pass the session's reported model identifier when
    /// available so a future routing case lands without a signature change.
    public static func forRemote(model: String) -> AgentBadgeSpec {
        // Phase 1 contract: every remote claude.ai session uses the Claude
        // badge. The `model` parameter is intentionally ignored today.
        _ = model
        return .forAgent(.claude)
    }
}
