import XCTest
import AppKit
import SwiftUI
@testable import SeshctlApp

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
}
