import SwiftUI
import SeshctlCore

/// Unified status vocabulary shared by `SessionRowView` (local sessions) and
/// `RemoteClaudeCodeRowView` (cloud sessions). Both row types map their
/// type-specific status onto this so the animated dot, color palette, and
/// unread-pill treatments live in one place.
public enum StatusKind: Equatable, Sendable {
    /// Agent is actively working — pulsing green.
    case working
    /// Agent is waiting on user input (permission prompt, pending action) —
    /// bright amber with a repeating ping ring. The loudest treatment goes to
    /// the state blocked on the user.
    case waiting
    /// Healthy and idle (turn finished) — solid gray. Kept quiet on purpose:
    /// unread turns are flagged by the unread pill / accent bar, not the dot.
    case idle
    /// Local: session ended normally. Hollow gray ring, no animation.
    case completed
    /// Remote: worker disconnected (claude.ai can't reach it). Hollow gray
    /// ring, no animation. Distinct from `.completed` semantically even though
    /// they render identically today.
    case offline
    /// Canceled — solid red (local only today).
    case canceled
    /// No longer authoritative — reaped local session, or auth-expired cached
    /// remote row. Dimmed gray.
    case stale
}

extension StatusKind {
    /// Dot color for this kind. Activity-monitor convention: green means the
    /// agent is running, gray means it isn't.
    public var color: Color {
        switch self {
        case .working: return .green
        case .waiting: return Self.waitingAmber
        case .idle, .completed, .offline: return .gray
        case .canceled: return .red
        case .stale: return .gray.opacity(0.5)
        }
    }

    /// Dot color dimmed by recency. Only the neutral gray kinds (idle,
    /// completed, offline) fade — yesterday is dimmer than today, older is
    /// dimmer still — so the eye lands on today's sessions first. Colored
    /// kinds keep full strength at any age; they're signals, not history.
    public func color(age: SessionAgeDisplay.AgeBucket) -> Color {
        switch self {
        case .idle, .completed, .offline:
            switch age {
            case .today: return color
            case .yesterday: return color.opacity(0.6)
            case .older: return color.opacity(0.35)
            }
        case .working, .waiting, .canceled, .stale:
            return color
        }
    }

    /// Vivid amber (#FFA500) for `.waiting`. System orange reads muddier than
    /// the system green used for `.working`; the attention state should be at
    /// least as vibrant as the busy one.
    public static let waitingAmber = Color(red: 1.0, green: 0.65, blue: 0.0)

    /// Whether the dot renders as an outline instead of a filled circle.
    /// Separates ended sessions from idle ones, which share the gray color.
    public var isHollow: Bool { self == .completed || self == .offline }

    /// Whether the `.working` pulse animation plays.
    public var isPulsing: Bool { self == .working }

    /// Whether the `.waiting` ping animation plays.
    public var isPinging: Bool { self == .waiting }
}

extension SessionStatus {
    /// Local session status → shared UI vocabulary.
    public var statusKind: StatusKind {
        switch self {
        case .working: return .working
        case .waiting: return .waiting
        case .idle: return .idle
        case .completed: return .completed
        case .canceled: return .canceled
        case .stale: return .stale
        }
    }
}

/// Decision table mapping a remote session's reported worker/connection
/// status (plus auth-staleness) to a shared `StatusKind`. Lives on
/// `StatusKind` rather than the row view so tests can exercise the decision
/// without constructing a view.
extension StatusKind {
    /// Compute the shared-vocabulary status for a remote Claude Code session.
    /// `isStale` beats everything — the cached row is no longer authoritative
    /// when auth has expired.
    public static func forRemote(
        workerStatus: String,
        connectionStatus: String,
        isStale: Bool
    ) -> StatusKind {
        if isStale { return .stale }
        switch RemoteWorkerStatus(rawValue: workerStatus) {
        case .running: return .working
        case .waiting, .requiresAction: return .waiting
        case .disconnected: return .offline
        case .idle, .none: break // fall through to connection check
        }
        if connectionStatus == RemoteConnectionStatus.disconnected.rawValue {
            return .offline
        }
        return .idle
    }
}
