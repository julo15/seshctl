import AppKit
import SwiftUI

/// A floating NSPanel that behaves like Spotlight:
/// - Doesn't appear in Cmd+Tab or Mission Control
/// - Stays above other windows
/// - Click outside to dismiss
/// - Vim-style keyboard navigation (j/k, arrows, enter, esc)
final class FloatingPanel: NSPanel {
    // Chrome constants — Spotlight-like translucent HUD glass.
    static let panelSize = NSSize(width: 900, height: 720)
    static let cornerRadius: CGFloat = 20
    static let borderWidth: CGFloat = 1
    static let borderAlpha: CGFloat = 0.15
    /// Black-tint alpha layered between the blur and the SwiftUI content
    /// to push the panel closer to Spotlight's near-black-glass look in
    /// dark mode (the bare `.underWindowBackground` material on its own
    /// reads as too gray). Tune freely; 0.0 disables the tint.
    static let darkTintAlpha: CGFloat = 0.35

    var onKeyDown: ((UInt16, String?, NSEvent.ModifierFlags) -> Void)?
    var onDismiss: (() -> Void)?

    init(rootView: some View) {
        super.init(
            contentRect: NSRect(origin: .zero, size: FloatingPanel.panelSize),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Floating behavior
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Hide traffic light buttons so titlebar is purely invisible
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

        // Visual style — Spotlight-like translucent glass
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        // Content stack (back-to-front): NSVisualEffectView (blur) →
        // black tint NSView (darkens the blur toward Spotlight's
        // near-black look) → NSHostingView (SwiftUI content).
        // Layer-backed effect view gives us rounded corners + hairline stroke;
        // masksToBounds clips everything to the rounded rect, and the window
        // shadow follows the resulting alpha mask.
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: FloatingPanel.panelSize))
        // `.underWindowBackground` is the densest vibrancy material; pairs
        // with the black tint below to land at Spotlight-grade darkness.
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.wantsLayer = true
        effect.layer?.cornerRadius = FloatingPanel.cornerRadius
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = FloatingPanel.borderWidth
        // Note: CGColor is captured at init; won't re-resolve on light/dark switch while the panel is open (panel is transient, so drift is narrow).
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(FloatingPanel.borderAlpha).cgColor
        contentView = effect

        // Black-tint overlay sits between the blur and the SwiftUI hosting
        // view so the wallpaper still bleeds through (preserved by the
        // vibrancy material) but is uniformly darkened by `darkTintAlpha`.
        let tint = NSView(frame: effect.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(FloatingPanel.darkTintAlpha).cgColor
        tint.autoresizingMask = [.width, .height]
        effect.addSubview(tint)

        // ignoresSafeArea so the view extends under the transparent titlebar
        let hostingView = NSHostingView(rootView: rootView.ignoresSafeArea())
        hostingView.frame = effect.bounds
        hostingView.autoresizingMask = [.width, .height]
        effect.addSubview(hostingView)
    }

    /// Center the panel on the main screen.
    func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.midY - frame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    func toggle() {
        if isVisible {
            orderOut(nil)
        } else {
            centerOnScreen()
            makeKeyAndOrderFront(nil)
        }
    }

    // Dismiss on click outside (but not when already hidden programmatically)
    override func resignKey() {
        super.resignKey()
        guard isVisible else { return }
        orderOut(nil)
        onDismiss?()
    }

    // Allow the panel to become key (for receiving keyboard events)
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers
        onKeyDown?(event.keyCode, chars, event.modifierFlags)
    }
}
