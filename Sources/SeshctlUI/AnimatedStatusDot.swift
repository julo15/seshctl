import SwiftUI

/// Colored dot with pulse/blink animations driven by a `StatusKind`. Replaces
/// the two near-identical ZStacks previously inlined in `SessionRowView` and
/// `RemoteClaudeCodeRowView` — any visual tweak (pulse timing, shadow radius,
/// halo sizes) now lives in exactly one place.
///
/// Intentionally small surface: you hand it a `StatusKind`, the view runs the
/// animation that `kind` implies. The `onChange` driver resets and restarts
/// the animations on status transitions.
public struct AnimatedStatusDot: View {
    public let kind: StatusKind
    @State private var isPulsing = false
    @State private var isBlinking = false

    public init(kind: StatusKind) {
        self.kind = kind
    }

    public var body: some View {
        let color = kind.color
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
            Circle()
                .fill(kind.isHollow ? .clear : color)
                .overlay {
                    if kind.isHollow {
                        Circle().strokeBorder(color, lineWidth: 1.5)
                    }
                }
                .frame(width: 8, height: 8)
                .shadow(
                    color: kind.isPulsing && isPulsing ? color.opacity(0.8) : .clear,
                    radius: kind.isPulsing && isPulsing ? 8 : 4
                )
                .scaleEffect(kind.isPulsing ? (isPulsing ? 1.15 : 0.85) : 1.0)
                .opacity(kind.isBlinking ? (isBlinking ? 1.0 : 0.3) : 1.0)
        }
        .drawingGroup()
        .onAppear { startAnimations() }
        .onChange(of: kind) { _ in
            isPulsing = false
            isBlinking = false
            startAnimations()
        }
    }

    private func startAnimations() {
        if kind.isPulsing {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        if kind.isBlinking {
            withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: true)) {
                isBlinking = true
            }
        }
    }
}
