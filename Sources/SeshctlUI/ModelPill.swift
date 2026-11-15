import SwiftUI

/// The model a row's session is running, shown as a small pill beside the
/// headline in the compact layout, and just left of the host-app icon in the
/// stacked layouts. Built by `SessionListViewModel.modelPill(for:)`.
public struct ModelPill: Equatable, Sendable {
    /// Short display name, e.g. `"Opus 5.5"` (see
    /// `TranscriptModelScanner.displayName(for:)`).
    public let name: String
    /// The model differs from the usual one for this row's agent, so the pill
    /// is tinted to stand out.
    public let isUnusual: Bool

    public init(name: String, isUnusual: Bool) {
        self.name = name
        self.isUnusual = isUnusual
    }
}

/// Renders a `ModelPill`: a quiet outlined label, amber when unusual.
struct ModelPillView: View {
    let pill: ModelPill

    /// Amber, matching the waiting-dot family without reusing its exact
    /// color, so an unusual model reads as "note this", not "blocked".
    private static let unusualColor = Color(red: 0.85, green: 0.64, blue: 0.25)

    var body: some View {
        Text(pill.name)
            .pillChrome(
                foreground: pill.isUnusual ? AnyShapeStyle(Self.unusualColor) : AnyShapeStyle(.secondary),
                border: pill.isUnusual ? Self.unusualColor.opacity(0.45) : Color.secondary.opacity(0.35)
            )
            .help(pill.isUnusual ? "\(pill.name) — not the usual model for this agent" : pill.name)
            .accessibilityLabel("Model \(pill.name)")
    }
}

/// A short neutral status tag drawn like the model pill, e.g. History's
/// "transcript deleted".
struct TagPillView: View {
    let text: String

    var body: some View {
        Text(text)
            .pillChrome(foreground: AnyShapeStyle(.secondary), border: Color.secondary.opacity(0.35))
    }
}

extension View {
    /// The model pill's look: small medium-weight text in a thin rounded
    /// outline. Shared so every pill on a row matches.
    func pillChrome(foreground: AnyShapeStyle, border: Color) -> some View {
        self
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(border, lineWidth: 1)
            )
    }
}
