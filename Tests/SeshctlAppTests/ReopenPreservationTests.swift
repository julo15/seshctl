import XCTest
@testable import SeshctlApp

/// Covers `AppDelegate.shouldPreserveDetail` — the time-window gate that keeps
/// an open transcript on reopen when the panel is reopened soon after closing.
final class ReopenPreservationTests: XCTestCase {
    private let window: TimeInterval = 180
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func test_neverClosed_doesNotPreserve() {
        XCTAssertFalse(
            AppDelegate.shouldPreserveDetail(lastCloseAt: nil, now: now, window: window),
            "A nil close time (e.g. first launch) should never preserve the detail view."
        )
    }

    func test_withinWindow_preserves() {
        let closedAt = now.addingTimeInterval(-100) // 100s ago, inside 180s
        XCTAssertTrue(
            AppDelegate.shouldPreserveDetail(lastCloseAt: closedAt, now: now, window: window)
        )
    }

    func test_justClosed_preserves() {
        XCTAssertTrue(
            AppDelegate.shouldPreserveDetail(lastCloseAt: now, now: now, window: window),
            "Zero elapsed time is within the window."
        )
    }

    func test_exactlyAtBoundary_preserves() {
        let closedAt = now.addingTimeInterval(-window) // exactly 180s ago
        XCTAssertTrue(
            AppDelegate.shouldPreserveDetail(lastCloseAt: closedAt, now: now, window: window),
            "The boundary is inclusive (<=)."
        )
    }

    func test_beyondWindow_doesNotPreserve() {
        let closedAt = now.addingTimeInterval(-(window + 1)) // 181s ago
        XCTAssertFalse(
            AppDelegate.shouldPreserveDetail(lastCloseAt: closedAt, now: now, window: window)
        )
    }

    // MARK: - Auto-dismiss after acting on a session

    func test_transientPanelDismissesAfterAction() {
        XCTAssertTrue(
            AppDelegate.shouldAutoDismissAfterAction(keepOpen: false),
            "Picking a session in Spotlight mode means \"take me there\" — the panel gets out of the way."
        )
    }

    func test_pinnedPanelSurvivesAction() {
        XCTAssertFalse(
            AppDelegate.shouldAutoDismissAfterAction(keepOpen: true),
            "A dashboard that vanishes every time you jump to a session isn't a dashboard."
        )
    }
}
