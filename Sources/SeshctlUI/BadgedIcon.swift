import SwiftUI

/// Composes a small corner badge over a base image — works uniformly for
/// `Image(nsImage:)` (host app icons) and `Image(systemName:)` (the globe
/// SF Symbol used on remote rows). The badge encodes the agent kind via
/// `AgentBadgeSpec`.
///
/// Carries a single unified accessibility label — the composite is read as
/// one element (`"Ghostty, Claude"`) rather than two unlabeled images. This
/// also fixes the prior gap where an empty `Color.clear` icon slot read as
/// "loading" to VoiceOver.
///
/// Phase 1 — Unit 3 of plan `2026-04-29-1730-row-ui-gmail-redesign.md`.
/// This view is introduced here but not yet wired into row views; Units
/// 5 and 6 swap call sites in `SessionRowView` / `RemoteClaudeCodeRowView`.
struct BadgedIcon: View {
    /// Caller-provided base image. Use `Image(nsImage:)` for host app
    /// icons or `Image(systemName:)` for SF Symbols (e.g. globe).
    let base: Image
    /// Agent-kind badge data — glyph + color. See `AgentBadgeSpec`.
    let badge: AgentBadgeSpec
    /// Side length of the base image's frame in points.
    var baseSize: CGFloat = 24
    /// Diameter of the badge circle in points. The 14/24 (~58%) ratio is
    /// larger than Apple's typical "stickered" mark (~33-40%) — bumped from
    /// 10pt in commit 8449f8a so the monogram letter (`X` / `G`) and
    /// the Claude mark stay legible at this site without antialiasing
    /// mush.
    var badgeSize: CGFloat = 14
    /// Unified VoiceOver label for the composite element. Construct via
    /// `Session.accessibilityLabel(hostApp:agent:)`.
    let accessibilityLabel: String

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            base
                .resizable()
                .frame(width: baseSize, height: baseSize)

            BadgeView(spec: badge, size: badgeSize)
                // Nudge the badge out so it sits visually in the
                // bottom-right *corner* of the base — a small overlap
                // beyond the icon's edge reads as a sticker rather than
                // an inset shape.
                .offset(x: badgeSize * 0.25, y: badgeSize * 0.25)
        }
        // Reserve space for the badge overhang so the composite's bounding
        // box matches what the layout sees. Without this, the trailing
        // offset would clip against neighboring views.
        .padding(.trailing, badgeSize * 0.25)
        .padding(.bottom, badgeSize * 0.25)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Private inner view rendering the colored circle + glyph (monogram
/// letter or vector mark). Kept inside `BadgedIcon.swift` because it
/// has no use outside this composite.
private struct BadgeView: View {
    let spec: AgentBadgeSpec
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(spec.color)
            // 1pt halo for separation against busy or transparent
            // bottom-right corners of the underlying icon.
            Circle()
                .strokeBorder(Color.white, lineWidth: 1)
            switch spec.glyph {
            case .letter(let s):
                Text(s)
                    .font(.system(size: size * 0.7, weight: .bold))
                    .foregroundStyle(spec.glyphColor)
            case .claudeMark:
                ClaudeLogoShape()
                    .fill(spec.glyphColor)
                    .padding(size * 0.14)
            case .codexMark:
                // Nearly fills the disc: the `>_` cut-out is the part that
                // identifies it, and it's barely 2pt tall at this size.
                CodexLogoShape()
                    .fill(spec.glyphColor, style: FillStyle(eoFill: true))
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
    }
}
