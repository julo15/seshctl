import Foundation

/// Leading-edge rate limiter for keyboard scroll commands. Each `allow(now:)`
/// returns `true` and stamps the timestamp if at least `minInterval` has
/// elapsed since the last accepted call; otherwise it returns `false` and
/// the caller drops the event. No trailing-edge fire.
public struct ScrollThrottle {
    public let minInterval: TimeInterval
    public private(set) var lastFiredAt: TimeInterval = 0

    public init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    public mutating func allow(now: TimeInterval) -> Bool {
        if now - lastFiredAt < minInterval { return false }
        lastFiredAt = now
        return true
    }
}

/// Keyboard-scroll timing constants shared across the transcript view.
/// `throttleMinInterval` MUST stay strictly greater than `animationDuration`
/// — otherwise successive accepted scrolls can queue overlapping
/// `NSAnimationContext` animations, which is what originally pegged the
/// main thread under held Ctrl+B.
public enum KeyboardScrollTiming {
    public static let throttleMinInterval: TimeInterval = 0.05
    public static let animationDuration: TimeInterval = 0.04
}
