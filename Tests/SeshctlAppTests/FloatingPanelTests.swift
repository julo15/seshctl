import XCTest
import AppKit
import SwiftUI
@testable import SeshctlApp

/// `@MainActor` because every assertion here touches AppKit state
/// (`FloatingPanel.init`, `contentView`, `level`, `frame`). Without it Swift 6
/// strict concurrency warns on each one from the nonisolated class body.
@MainActor
final class FloatingPanelTests: XCTestCase {
    func test_panelIsTransparent() {
        let panel = FloatingPanel(rootView: EmptyView())
        XCTAssertFalse(panel.isOpaque, "Panel should not be opaque so the visual-effect blur shows through.")
        XCTAssertEqual(panel.backgroundColor, .clear, "Panel backgroundColor should be .clear.")
    }

    func test_contentViewIsVisualEffectWithUnderWindowMaterial() {
        let panel = FloatingPanel(rootView: EmptyView())
        guard let effect = panel.contentView as? NSVisualEffectView else {
            XCTFail("Expected contentView to be an NSVisualEffectView, got \(String(describing: panel.contentView)).")
            return
        }
        XCTAssertEqual(effect.material, .underWindowBackground, "Visual effect material should be .underWindowBackground.")
        XCTAssertEqual(effect.blendingMode, .behindWindow, "Visual effect blending mode should be .behindWindow.")
        XCTAssertEqual(effect.state, .active, "Visual effect state should be .active.")
    }

    func test_panelForcesDarkAppearance() {
        let panel = FloatingPanel(rootView: EmptyView())
        XCTAssertEqual(panel.appearance?.name, .darkAqua, "Panel should pin appearance to .darkAqua so the dark-glass chrome stays consistent in light mode.")
    }

    func test_darkTintOverlaySitsBetweenBlurAndHostingView() {
        let panel = FloatingPanel(rootView: EmptyView())
        guard let effect = panel.contentView as? NSVisualEffectView else {
            XCTFail("Expected contentView to be an NSVisualEffectView.")
            return
        }
        XCTAssertEqual(effect.subviews.count, 2, "Effect view should have two subviews: the dark tint behind and the hosting view in front.")
        guard let tint = effect.subviews.first else {
            XCTFail("Expected effect view's first subview to be the tint overlay.")
            return
        }
        // The tint is a plain NSView, not an NSHostingView.
        let tintTypeName = String(describing: type(of: tint))
        XCTAssertFalse(tintTypeName.hasPrefix("NSHostingView<"), "First subview should be the plain NSView tint, not the hosting view.")
        XCTAssertTrue(tint.wantsLayer, "Tint subview should be layer-backed.")
        guard let layer = tint.layer, let cgColor = layer.backgroundColor else {
            XCTFail("Tint subview should have a backing layer with a background color.")
            return
        }
        XCTAssertEqual(cgColor.alpha, FloatingPanel.darkTintAlpha, accuracy: 0.001, "Tint background alpha should match darkTintAlpha.")
        XCTAssertTrue(tint.autoresizingMask.contains(.width), "Tint autoresizing mask should contain .width.")
        XCTAssertTrue(tint.autoresizingMask.contains(.height), "Tint autoresizing mask should contain .height.")
    }

    func test_contentViewHasRoundedCornersAndBorder() {
        let panel = FloatingPanel(rootView: EmptyView())
        guard let effect = panel.contentView as? NSVisualEffectView else {
            XCTFail("Expected contentView to be an NSVisualEffectView.")
            return
        }
        XCTAssertTrue(effect.wantsLayer, "Effect view should be layer-backed.")
        guard let layer = effect.layer else {
            XCTFail("Expected effect view to have a backing layer.")
            return
        }
        XCTAssertEqual(layer.cornerRadius, FloatingPanel.cornerRadius, "Corner radius should be 20.")
        XCTAssertTrue(layer.masksToBounds, "Layer should mask to bounds to clip blur + content to rounded rect.")
        XCTAssertEqual(layer.borderWidth, FloatingPanel.borderWidth, "Border width should be 1 (hairline stroke).")
        XCTAssertNotNil(layer.borderColor, "Border color should be set.")
    }

    func test_hostingViewIsTopmostSubviewOfEffectView() {
        let panel = FloatingPanel(rootView: EmptyView())
        guard let effect = panel.contentView as? NSVisualEffectView else {
            XCTFail("Expected contentView to be an NSVisualEffectView.")
            return
        }
        // Hosting view is the LAST subview so it renders on top of the
        // dark-tint overlay added in front of the blur.
        guard let hostingView = effect.subviews.last else {
            XCTFail("Expected effect view to have at least one subview.")
            return
        }
        let typeName = String(describing: type(of: hostingView))
        XCTAssertTrue(
            typeName.hasPrefix("NSHostingView<"),
            "Expected last subview to be an NSHostingView (topmost in z-order), got type \(typeName)."
        )
        XCTAssertTrue(
            hostingView.autoresizingMask.contains(.width),
            "Hosting view autoresizing mask should contain .width."
        )
        XCTAssertTrue(
            hostingView.autoresizingMask.contains(.height),
            "Hosting view autoresizing mask should contain .height."
        )
    }

    func test_shadowAndFloatingBehaviorPreserved() {
        let panel = FloatingPanel(rootView: EmptyView())
        XCTAssertTrue(panel.hasShadow, "Panel should have a shadow.")
        XCTAssertEqual(panel.level, .floating, "Panel level should be .floating.")
        XCTAssertTrue(panel.isFloatingPanel, "Panel should be marked as a floating panel.")
    }

    // MARK: - Keep-open mode

    func test_defaultsToTransientSpotlightMode() {
        let panel = FloatingPanel(rootView: EmptyView())
        XCTAssertFalse(panel.keepOpen, "Panel should default to the transient Spotlight mode.")
        XCTAssertEqual(panel.level, .floating, "Transient mode should sit at .floating so it overlays other windows.")
    }

    func test_setWindowModeDropsPinnedPanelToNormalLevel() {
        let panel = FloatingPanel(rootView: EmptyView())
        panel.setWindowMode(keepOpen: true, alwaysInFront: false)
        XCTAssertTrue(panel.keepOpen)
        XCTAssertFalse(panel.alwaysInFront)
        XCTAssertEqual(
            panel.level, .normal,
            "A pinned panel must drop to .normal so other windows on that screen can cover it."
        )
    }

    func test_setWindowModeIsReversible() {
        let panel = FloatingPanel(rootView: EmptyView())
        panel.setWindowMode(keepOpen: true, alwaysInFront: false)
        panel.setWindowMode(keepOpen: false, alwaysInFront: false)
        XCTAssertFalse(panel.keepOpen)
        XCTAssertEqual(panel.level, .floating, "Turning keep-open off should restore the .floating overlay level.")
    }

    func test_alwaysInFrontKeepsPinnedPanelFloating() {
        let panel = FloatingPanel(rootView: EmptyView())
        panel.setWindowMode(keepOpen: true, alwaysInFront: true)
        XCTAssertTrue(panel.alwaysInFront)
        XCTAssertEqual(panel.level, .floating, "\"Always in front\" must hold a pinned panel above other windows.")
    }

    func test_windowLevelMatrix() {
        // Transient panel: always on top regardless of the setting. A Spotlight
        // overlay that other windows could cover would be useless, so
        // `alwaysInFront` has no say until the panel is pinned.
        XCTAssertEqual(FloatingPanel.windowLevel(keepOpen: false, alwaysInFront: false), .floating)
        XCTAssertEqual(FloatingPanel.windowLevel(keepOpen: false, alwaysInFront: true), .floating)
        // Pinned: the setting decides.
        XCTAssertEqual(FloatingPanel.windowLevel(keepOpen: true, alwaysInFront: false), .normal)
        XCTAssertEqual(FloatingPanel.windowLevel(keepOpen: true, alwaysInFront: true), .floating)
    }

    // MARK: - Focus dimming

    func test_panelAlphaMatrix() {
        // Transient panel: never dims. It orders itself out on resign-key, so a
        // dim would only be visible mid-dismissal and would strand a sub-1.0
        // alpha for the next summon.
        XCTAssertEqual(FloatingPanel.panelAlpha(keepOpen: false, isKey: true), 1.0)
        XCTAssertEqual(FloatingPanel.panelAlpha(keepOpen: false, isKey: false), 1.0)
        // Pinned: focus decides. This is the only cue telling the user whether
        // keystrokes reach seshctl or the terminal behind it.
        XCTAssertEqual(FloatingPanel.panelAlpha(keepOpen: true, isKey: true), 1.0)
        XCTAssertEqual(
            FloatingPanel.panelAlpha(keepOpen: true, isKey: false),
            FloatingPanel.unfocusedAlpha
        )
    }

    func test_isInUseMatrix() {
        // Hidden: never in use, whatever stale focus/hover flags say.
        XCTAssertFalse(FloatingPanel.isInUse(isVisible: false, isKey: true, isMouseInside: true))
        // Visible: in use when focused or hovered — the user may be about to
        // click a row, so the list mustn't reorder under them.
        XCTAssertTrue(FloatingPanel.isInUse(isVisible: true, isKey: true, isMouseInside: false))
        XCTAssertTrue(FloatingPanel.isInUse(isVisible: true, isKey: false, isMouseInside: true))
        // A pinned panel sitting unfocused and unhovered is a glanceable
        // dashboard, free to re-sort.
        XCTAssertFalse(FloatingPanel.isInUse(isVisible: true, isKey: false, isMouseInside: false))
    }

    func test_contentViewTracksMouseEnterAndExit() throws {
        let panel = FloatingPanel(rootView: EmptyView())
        let effect = try XCTUnwrap(panel.contentView)
        let area = try XCTUnwrap(effect.trackingAreas.first { $0.owner === panel })
        XCTAssertTrue(area.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(area.options.contains(.activeAlways), "A pinned panel is often not key; hover must still register.")
        XCTAssertTrue(area.options.contains(.inVisibleRect), "The area must follow the panel when it's resized.")
    }

    func test_mouseEnterAndExitUpdateHoverAndNotify() throws {
        let panel = FloatingPanel(rootView: EmptyView())
        var notifications = 0
        panel.onInteractionChange = { notifications += 1 }
        let event = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))

        panel.mouseEntered(with: event)
        XCTAssertTrue(panel.isMouseInside)
        panel.mouseExited(with: event)
        XCTAssertFalse(panel.isMouseInside)
        XCTAssertEqual(notifications, 2)
    }

    func test_unfocusedAlphaStaysReadable() {
        // The blur is `.behindWindow`, so the window alpha re-blends the already
        // composited panel against the desktop. Too low reads as washed-out
        // rather than see-through; 1.0 would make the cue invisible.
        XCTAssertLessThan(FloatingPanel.unfocusedAlpha, 1.0)
        XCTAssertGreaterThanOrEqual(FloatingPanel.unfocusedAlpha, 0.7)
    }

    func test_turningKeepOpenOffRestoresFullOpacity() {
        let panel = FloatingPanel(rootView: EmptyView())
        // Pinned and unfocused (a freshly-built panel is not key) → dimmed.
        panel.setWindowMode(keepOpen: true, alwaysInFront: false)
        XCTAssertEqual(panel.alphaValue, FloatingPanel.unfocusedAlpha, accuracy: 0.001)
        // Back to transient — the panel must not be stranded at the dim alpha,
        // or every subsequent Spotlight-style summon shows up translucent.
        panel.setWindowMode(keepOpen: false, alwaysInFront: false)
        XCTAssertEqual(panel.alphaValue, 1.0, accuracy: 0.001)
    }

    // MARK: - Resizing

    func test_panelIsResizableWithAFloor() {
        let panel = FloatingPanel(rootView: EmptyView())
        XCTAssertTrue(
            panel.styleMask.contains(.resizable),
            "Panel must be resizable — the user drags its edges to size the dashboard."
        )
        XCTAssertEqual(
            panel.minSize, FloatingPanel.minPanelSize,
            "A floor keeps the panel from collapsing past the point where rows truncate; the titlebar is hidden so there's no chrome to grab."
        )
    }

    func test_resignKeyDismissesOnlyInTransientMode() {
        // Transient + visible is the only combination that dismisses.
        XCTAssertTrue(FloatingPanel.shouldDismissOnResignKey(keepOpen: false, isVisible: true))
        // Keep-open mode: losing key focus is the normal state, never a dismiss.
        XCTAssertFalse(
            FloatingPanel.shouldDismissOnResignKey(keepOpen: true, isVisible: true),
            "A pinned panel must survive losing focus — that's the entire point of the mode."
        )
        // Already hidden: nothing to order out, and firing onDismiss again would
        // double-count the close in the view model's bookkeeping.
        XCTAssertFalse(FloatingPanel.shouldDismissOnResignKey(keepOpen: false, isVisible: false))
        XCTAssertFalse(FloatingPanel.shouldDismissOnResignKey(keepOpen: true, isVisible: false))
    }

    // MARK: - Position persistence

    func test_frameIsAutosavedSoTheParkedScreenIsRemembered() {
        let panel = FloatingPanel(rootView: EmptyView())
        XCTAssertEqual(
            panel.frameAutosaveName, FloatingPanel.frameAutosaveName,
            "Without an autosave name the panel forgets which screen the user parked it on."
        )
    }

    func test_onlyAPinnedPlacedPanelKeepsItsPlacement() {
        XCTAssertTrue(FloatingPanel.keepsPlacement(keepOpen: true, hasPlacement: true, isOnScreen: true))
        XCTAssertFalse(FloatingPanel.keepsPlacement(keepOpen: true, hasPlacement: false, isOnScreen: true),
                       "A pinned panel with nowhere saved still needs centering once.")
        XCTAssertFalse(FloatingPanel.keepsPlacement(keepOpen: true, hasPlacement: true, isOnScreen: false),
                       "A panel parked on a disconnected display must come back on screen.")
        XCTAssertFalse(FloatingPanel.keepsPlacement(keepOpen: false, hasPlacement: true, isOnScreen: true),
                       "The transient panel follows the active screen, like Spotlight.")
        XCTAssertFalse(FloatingPanel.keepsPlacement(keepOpen: false, hasPlacement: false, isOnScreen: true))
    }

    func test_transientPanelRecentersEvenAfterBeingMoved() throws {
        let screen = try XCTUnwrap(NSScreen.main, "Test host needs a screen for the centering path.")
        let panel = FloatingPanel(rootView: EmptyView())
        panel.setWindowMode(keepOpen: false, alwaysInFront: false)
        panel.centerOnScreen()
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY))

        panel.centerOnScreen()

        XCTAssertEqual(panel.frame.midX, screen.visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, screen.visibleFrame.midY, accuracy: 1)
        XCTAssertEqual(panel.frame.size, size, "Centering should move the panel, not resize it.")
    }

    func test_pinnedPanelStaysWhereItWasParked() throws {
        let screen = try XCTUnwrap(NSScreen.main, "Test host needs a screen for the centering path.")
        let panel = FloatingPanel(rootView: EmptyView())
        panel.setWindowMode(keepOpen: true, alwaysInFront: false)
        panel.centerOnScreen()
        let parked = NSPoint(x: screen.visibleFrame.minX + 10, y: screen.visibleFrame.minY + 10)
        panel.setFrameOrigin(parked)

        panel.centerOnScreen()

        XCTAssertEqual(panel.frame.origin, parked, "Re-centering would drag a parked panel off its monitor.")
    }
}
