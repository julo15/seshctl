import AppKit
import SwiftUI

/// A floating NSPanel that behaves like Spotlight:
/// - The panel window itself stays out of Mission Control and the window list.
///   (The *app* is Cmd+Tab-reachable — `LSUIElement` is off and
///   `AppDelegate.applicationDidBecomeActive` shows this panel on activation.)
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
    /// to push the panel closer to Spotlight's near-black-glass look (the
    /// bare `.underWindowBackground` material on its own reads as too
    /// gray). The panel forces `.darkAqua` appearance so this tint is
    /// always evaluated against a dark material. Tune freely; 0.0
    /// disables the tint.
    static let darkTintAlpha: CGFloat = 0.35
    /// Window alpha for a *pinned* panel that doesn't hold key focus. The only
    /// cue distinguishing "keystrokes land in seshctl" from "keystrokes land in
    /// your terminal": the panel pins itself to `.darkAqua`, forces
    /// `NSVisualEffectView.state = .active`, and draws its own selection
    /// highlight, so none of macOS's usual active/inactive chrome applies and an
    /// unfocused panel would otherwise look identical to a focused one.
    ///
    /// Applies to keep-open mode only — a transient panel dismisses itself on
    /// resign-key, so it has no visible-but-unfocused state to signal. Tune
    /// freely alongside `darkTintAlpha`; note the blur is `.behindWindow`, so
    /// lowering this re-blends the composited window against the desktop and
    /// values much below ~0.7 read as washed-out rather than see-through.
    static let unfocusedAlpha: CGFloat = 0.8

    /// Floor for user resizing. The row list needs roughly this much width
    /// before the repo/branch/preview columns start truncating into nonsense,
    /// and the titlebar is hidden so there's no chrome to grab on a tiny panel.
    static let minPanelSize = NSSize(width: 520, height: 320)

    /// AppKit autosave slot for the panel frame. Position is remembered in both
    /// modes: a user who drags the panel to a second monitor must get it back
    /// there on the next show, not yanked to whatever `NSScreen.main` happens
    /// to be at the time.
    static let frameAutosaveName = "SeshctlSessionPanel"

    var onKeyDown: ((UInt16, String?, NSEvent.ModifierFlags) -> Void)?
    var onDismiss: (() -> Void)?

    /// When true the panel stops behaving like a Spotlight overlay: losing key
    /// focus no longer dismisses it, and it sits at `.normal` level so other
    /// windows can cover it. Drives the "Keep panel open" setting
    /// (`AppearanceDefaults.keepPanelOpenKey`); apply changes through
    /// `setKeepOpen(_:)` so the window level moves with it.
    private(set) var keepOpen = false

    /// Whether a pinned panel keeps the `.floating` always-on-top level. Drives
    /// the "Always in front" setting (`AppearanceDefaults.panelAlwaysInFrontKey`).
    /// Ignored while `keepOpen` is false — see `windowLevel(keepOpen:alwaysInFront:)`.
    private(set) var alwaysInFront = false

    /// True when AppKit restored a previously saved frame at init, meaning the
    /// user has parked this panel somewhere deliberate. `centerOnScreen()`
    /// checks this so a show never overrides that choice.
    private(set) var didRestoreSavedFrame = false

    init(rootView: some View) {
        super.init(
            contentRect: NSRect(origin: .zero, size: FloatingPanel.panelSize),
            // `.resizable` lets the user drag the panel's edges. Size rides the
            // same frame autosave as position, so a resized panel comes back at
            // that size. The blur, tint, and hosting views all carry
            // width/height autoresizing masks, so the content follows.
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
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
        minSize = FloatingPanel.minPanelSize
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

        // Visual style — Spotlight-like translucent glass. Pin the panel
        // to `.darkAqua` regardless of system appearance so the dark-glass
        // chrome stays consistent in light mode too (Spotlight does the
        // same — it's always dark-glass).
        appearance = NSAppearance(named: .darkAqua)
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
        // `.underWindowBackground` is among the densest vibrancy
        // materials; paired with the black tint below it lands at
        // Spotlight-grade darkness. Off-label for in-window content but
        // empirically the closest visual match.
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

        // Restore the parked position first, then enable autosaving so every
        // subsequent move is written back. Order matters: naming the autosave
        // slot before restoring can persist the default centered frame over the
        // user's saved one.
        didRestoreSavedFrame = setFrameUsingName(Self.frameAutosaveName)
        setFrameAutosaveName(Self.frameAutosaveName)
    }

    /// The window level implied by the two panel settings. Pure + static so the
    /// matrix is unit-testable without a live window.
    ///
    /// A *transient* panel is always `.floating`: it's a Spotlight-style overlay
    /// summoned over whatever you're doing, and one that other windows could
    /// cover would be useless. So `alwaysInFront` only has a say once the panel
    /// is pinned, where `.normal` lets it behave like an ordinary window on a
    /// spare monitor and `.floating` keeps it above everything.
    static func windowLevel(keepOpen: Bool, alwaysInFront: Bool) -> NSWindow.Level {
        (keepOpen && !alwaysInFront) ? .normal : .floating
    }

    /// The window alpha implied by focus state. Pure + static so the rule is
    /// unit-testable without a live window, mirroring `windowLevel`.
    ///
    /// Only a pinned, unfocused panel dims. A transient panel orders itself out
    /// the moment it resigns key, so dimming it would only ever be visible mid-
    /// dismissal — and leaving a stale sub-1.0 alpha behind would then show up on
    /// the next summon.
    static func panelAlpha(keepOpen: Bool, isKey: Bool) -> CGFloat {
        (keepOpen && !isKey) ? unfocusedAlpha : 1.0
    }

    /// Apply both panel settings at once. They jointly determine the window
    /// level, so setting them independently would let the level go momentarily
    /// wrong between the two calls.
    func setWindowMode(keepOpen: Bool, alwaysInFront: Bool) {
        self.keepOpen = keepOpen
        self.alwaysInFront = alwaysInFront
        level = Self.windowLevel(keepOpen: keepOpen, alwaysInFront: alwaysInFront)
        // The alpha rule reads `keepOpen`, so the mode flip has to re-evaluate
        // it: turning keep-open on while the panel sits unfocused should dim it
        // immediately, and turning it off must restore full opacity rather than
        // stranding the panel at `unfocusedAlpha`.
        applyFocusAlpha(isKey: isKeyWindow)
    }

    /// Snap the window to the alpha implied by `keepOpen` + focus state.
    ///
    /// Deliberately not animated. `animator().alphaValue` drives the model value
    /// over time, so `alphaValue` reads stale immediately after the call — which
    /// both defeats the idempotence guard below and makes the state untestable.
    /// An instant flip also matches how macOS switches its own active/inactive
    /// window chrome, and immediate feedback is the whole point of the cue.
    private func applyFocusAlpha(isKey: Bool) {
        let target = Self.panelAlpha(keepOpen: keepOpen, isKey: isKey)
        guard abs(alphaValue - target) > 0.001 else { return }
        alphaValue = target
    }

    /// Center the panel on the active screen — but only when the user hasn't
    /// already placed it. Once a frame has been saved, showing the panel must
    /// respect it: re-centering is what drags a panel parked on a third monitor
    /// back to whichever screen is currently active.
    func centerOnScreen() {
        guard !didRestoreSavedFrame else { return }
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

    /// Whether losing key focus should dismiss the panel. Pure + static so the
    /// rule is unit-testable without a real key window (mirrors
    /// `AppDelegate.shouldPreserveDetail`).
    ///
    /// In keep-open mode losing key focus is the *normal* state — the whole
    /// point is to watch the panel on another screen while working elsewhere —
    /// so dismissing there would defeat the mode entirely.
    static func shouldDismissOnResignKey(keepOpen: Bool, isVisible: Bool) -> Bool {
        !keepOpen && isVisible
    }

    /// Dismiss on click outside — the Spotlight affordance. A pinned panel stays
    /// put and dims instead.
    override func resignKey() {
        super.resignKey()
        applyFocusAlpha(isKey: false)
        guard Self.shouldDismissOnResignKey(keepOpen: keepOpen, isVisible: isVisible) else { return }
        orderOut(nil)
        onDismiss?()
    }

    /// Undim on regaining focus. Also covers a summon of a hidden pinned panel:
    /// `makeKeyAndOrderFront` lands here, so it comes back opaque.
    override func becomeKey() {
        super.becomeKey()
        applyFocusAlpha(isKey: true)
    }

    // Allow the panel to become key (for receiving keyboard events)
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers
        onKeyDown?(event.keyCode, chars, event.modifierFlags)
    }
}
