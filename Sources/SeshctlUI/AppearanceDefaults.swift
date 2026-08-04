import Foundation

/// Single source of truth for appearance-related UserDefaults keys.
/// Views wire `@AppStorage(AppearanceDefaults.repoAccentBarKey)` instead of
/// hard-coding the key string — avoids typo drift across the ~5 views that
/// observe the same setting.
public enum AppearanceDefaults {
    /// Key for the "Repo color coding" toggle. Follows the `seshctl.`
    /// prefix convention used by `SessionListViewModel` for other
    /// UserDefaults keys.
    public static let repoAccentBarKey = "seshctl.repoAccentBarEnabled"

    /// Default for the toggle — off, so fresh installs see a clean,
    /// uncolored row list. Users who previously toggled it on keep their
    /// preference via `migrateLegacyKey` and ordinary UserDefaults
    /// persistence.
    public static let repoAccentBarDefault = false

    /// Key for the "Show menu bar icon" toggle.
    public static let showStatusBarIconKey = "seshctl.showStatusBarIcon"

    /// Default — on, so users discover the app's menu surface out of the box.
    public static let showStatusBarIconDefault = true

    /// Key for the "Stacked row layout" toggle. When on (default),
    /// session rows render the sender / branch / preview as a vertical
    /// stack spanning the full row width. When off, falls back to the
    /// legacy two-column layout where the sender column sits at a fixed
    /// 180pt on the left and the preview occupies the remaining width on
    /// the right. Exists for A/B comparison during the stacked-layout
    /// shakedown — once a winner is picked, the toggle and the losing
    /// code paths should be removed together.
    public static let stackedRowLayoutKey = "seshctl.stackedRowLayout"

    /// Default — on. The stacked layout is the new default; the toggle
    /// lets the user flip back to the two-column legacy for comparison.
    public static let stackedRowLayoutDefault = true

    /// Key for the "Keep panel open" toggle. When on, the session panel stops
    /// behaving like a Spotlight overlay: it no longer dismisses itself when it
    /// loses key focus, and it drops from `.floating` to `.normal` window level
    /// so other windows can sit above it. Intended for parking the panel on a
    /// spare monitor as a always-visible dashboard.
    ///
    /// Panel *position* is persisted independently of this toggle (see
    /// `FloatingPanel.frameAutosaveName`) — a panel the user has moved is
    /// restored where they left it in either mode.
    public static let keepPanelOpenKey = "seshctl.keepPanelOpen"

    /// Default — off, preserving the Spotlight-style transient panel that the
    /// hotkey UX is built around.
    public static let keepPanelOpenDefault = false

    /// Key for the "Always in front" toggle. Only meaningful alongside
    /// `keepPanelOpenKey`: it decides whether a pinned panel keeps the
    /// `.floating` level (above every other window, like the transient panel)
    /// or drops to `.normal` so other windows can cover it. A *transient* panel
    /// is always `.floating` — an overlay that other windows could hide would
    /// be useless — so this setting has no effect while keep-open is off.
    public static let panelAlwaysInFrontKey = "seshctl.panelAlwaysInFront"

    /// Default — off. A pinned panel parked on a spare monitor behaves like an
    /// ordinary window unless the user explicitly asks for always-on-top.
    public static let panelAlwaysInFrontDefault = false

    /// One-shot migration from the pre-release un-prefixed key
    /// (`"repoAccentBarEnabled"`) to `seshctl.repoAccentBarEnabled`.
    /// Run once at app launch so an author who toggled the setting during
    /// dev doesn't silently lose their choice when the key rename ships.
    /// Safe to call repeatedly — no-op after the first successful copy.
    public static func migrateLegacyKey(defaults: UserDefaults = .standard) {
        let legacy = "repoAccentBarEnabled"
        guard defaults.object(forKey: legacy) != nil,
              defaults.object(forKey: repoAccentBarKey) == nil else {
            return
        }
        defaults.set(defaults.bool(forKey: legacy), forKey: repoAccentBarKey)
        defaults.removeObject(forKey: legacy)
    }
}
