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

    // MARK: - Activation policy

    func test_transientPanelKeepsAMenuBarOnlyApp() {
        XCTAssertEqual(
            AppDelegate.activationPolicy(keepOpen: false), .accessory,
            "Users who never pin the panel must not get a Dock icon."
        )
    }

    func test_pinnedPanelGetsDockAndCmdTab() {
        XCTAssertEqual(AppDelegate.activationPolicy(keepOpen: true), .regular)
    }

    // MARK: - Activation shows the panel

    private func activation(
        isRegular: Bool = true, sinceLaunch: TimeInterval = 60,
        hasModal: Bool = false, hasOtherWindow: Bool = false
    ) -> Bool {
        AppDelegate.shouldShowPanelOnActivation(
            isRegular: isRegular, sinceLaunch: sinceLaunch,
            hasModal: hasModal, hasOtherWindow: hasOtherWindow)
    }

    func test_cmdTabToAPinnedAppShowsThePanel() {
        XCTAssertTrue(activation())
    }

    func test_menuBarModeNeverShowsThePanelOnActivation() {
        XCTAssertFalse(activation(isRegular: false),
                       "Only the Dock-mode app treats activation as \"show the panel\".")
    }

    func test_launchActivationIsIgnored() {
        XCTAssertFalse(activation(sinceLaunch: 0.1), "Login must not pop the panel over the desktop.")
        XCTAssertTrue(activation(sinceLaunch: AppDelegate.launchActivationGrace),
                      "After the grace, a real Cmd+Tab must not be swallowed.")
    }

    func test_activationForAModalOrAnotherWindowIsLeftAlone() {
        XCTAssertFalse(activation(hasModal: true), "The panel would cover the alert it was raised for.")
        XCTAssertFalse(activation(hasOtherWindow: true),
                       "Sparkle's prompt or Editor Integrations activated the app, not the user.")
    }

    // MARK: - Hotkey / status item toggle

    func test_toggleShowsAHiddenPanelInEitherMode() {
        XCTAssertEqual(AppDelegate.toggleAction(keepOpen: false, isVisible: false, isKey: false), .show)
        XCTAssertEqual(AppDelegate.toggleAction(keepOpen: true, isVisible: false, isKey: false), .show)
    }

    func test_toggleFocusesAPinnedPanelThatIsVisibleButUnfocused() {
        XCTAssertEqual(AppDelegate.toggleAction(keepOpen: true, isVisible: true, isKey: false), .focus,
                       "Otherwise the hotkey could never reach a parked panel.")
    }

    func test_toggleHidesAFocusedPanel() {
        XCTAssertEqual(AppDelegate.toggleAction(keepOpen: true, isVisible: true, isKey: true), .hide)
        XCTAssertEqual(AppDelegate.toggleAction(keepOpen: false, isVisible: true, isKey: true), .hide)
        XCTAssertEqual(AppDelegate.toggleAction(keepOpen: false, isVisible: true, isKey: false), .hide,
                       "A transient panel has no visible-but-unfocused state worth focusing.")
    }

    func test_pinnedPanelSurvivesAction() {
        XCTAssertFalse(
            AppDelegate.shouldAutoDismissAfterAction(keepOpen: true),
            "A dashboard that vanishes every time you jump to a session isn't a dashboard."
        )
    }
}
