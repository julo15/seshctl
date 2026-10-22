import SwiftUI

/// Colored dot with pulse/ping animations driven by a `StatusKind`. Replaces
/// the two near-identical ZStacks previously inlined in `SessionRowView` and
/// `RemoteClaudeCodeRowView` — any visual tweak (pulse timing, shadow radius,
/// halo sizes) now lives in exactly one place.
///
/// Intentionally small surface: you hand it a `StatusKind`, the view runs the
/// animation that `kind` implies.
public struct AnimatedStatusDot: View {
    public let kind: StatusKind
    /// Recency bucket of the session; dims the neutral gray kinds.
    public let age: SessionAgeDisplay.AgeBucket

    public init(kind: StatusKind, age: SessionAgeDisplay.AgeBucket = .today) {
        self.kind = kind
        self.age = age
    }

    public var body: some View {
        // A running repeatForever animation can't be cancelled by resetting
        // its state — it keeps driving the scale/opacity, so a session that
        // went working -> idle kept pulsing in gray. Keying the view on
        // `kind` rebuilds it on every status change, discarding the old
        // animation along with its state.
        DotBody(kind: kind, age: age)
            .id(kind)
    }
}

private struct DotBody: View {
    let kind: StatusKind
    let age: SessionAgeDisplay.AgeBucket
    @State private var isPulsing = false
    @State private var isPinging = false

    var body: some View {
        let color = kind.color(age: age)
        ZStack {
            if kind.isPulsing {
                Circle()
                    .fill(color.opacity(0.4))
                    .frame(width: 22, height: 22)
                    .scaleEffect(isPulsing ? 1.2 : 0.6)
                    .opacity(isPulsing ? 0.0 : 1.0)
                Circle()
                    .fill(color.opacity(0.25))
                    .frame(width: 22, height: 22)
                    .scaleEffect(isPulsing ? 1.8 : 0.6)
                    .opacity(isPulsing ? 0.0 : 0.6)
            }
            // Waiting is the state that most needs the user, so it gets the
            // loudest treatment: the dot never fades (a fading orange reads
            // as dull brown on the dark row), it glows softly, and a ring
            // repeatedly radiates outward like a radar ping.
            // strokeBorder keeps the ring inside its frame, so it starts
            // hidden behind the dot instead of padding it out by a stroke.
            if kind.isPinging {
                Circle()
                    .strokeBorder(color, lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isPinging ? 2.8 : 1.0)
                    .opacity(isPinging ? 0.0 : 0.9)
            }
            Circle()
                .fill(kind.isHollow ? .clear : color)
                .overlay {
                    if kind.isHollow {
                        Circle().strokeBorder(color, lineWidth: 1.5)
                    }
                }
                .frame(width: 8, height: 8)
                .shadow(
                    color: glowColor(color),
                    radius: kind.isPulsing ? (isPulsing ? 8 : 4) : 2.5
                )
                .scaleEffect(kind.isPulsing ? (isPulsing ? 1.15 : 0.85) : 1.0)
        }
        // drawingGroup rasterizes into the ZStack's bounds. Without a fixed
        // frame, kinds with no 22pt halo get an 8x8 buffer that clips the
        // scaled dot, glow, and ping ring into a square. Safe for layout:
        // ResultRowLayout hosts the dot as an overlay.
        .frame(width: 28, height: 28)
        .drawingGroup()
        .onAppear { startAnimations() }
    }

    /// Working glows at the peak of its pulse. Waiting glows constantly, so
    /// it's kept soft — at full strength it reads as harsher than the green.
    private func glowColor(_ color: Color) -> Color {
        if kind.isPulsing && isPulsing { return color.opacity(0.8) }
        if kind.isPinging { return color.opacity(0.35) }
        return .clear
    }

    private func startAnimations() {
        if kind.isPulsing {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        if kind.isPinging {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                isPinging = true
            }
        }
    }
}
