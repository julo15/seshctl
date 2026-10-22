import SwiftUI

/// The model a row's session is running, shown as a small pill just left of
/// the host-app icon. Built by `SessionListViewModel.modelPill(for:)`.
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
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(pill.isUnusual ? AnyShapeStyle(Self.unusualColor) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(pill.isUnusual ? Self.unusualColor.opacity(0.45) : Color.secondary.opacity(0.35), lineWidth: 1)
            )
            .help(pill.isUnusual ? "\(pill.name) — not the usual model for this agent" : pill.name)
            .accessibilityLabel("Model \(pill.name)")
    }
}
