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

    /// Key for the "Show agent name" toggle. When on, each row's subtitle leads
    /// with the agent that owns the session ("Claude Code", "Codex", …).
    ///
    /// The corner badge already encodes the agent as a colored monogram, but it
    /// is suppressed whenever every visible session shares one agent
    /// (`SessionListViewModel.hasMultipleAgentTypes`) — so a list of only Claude
    /// Code sessions shows no agent anywhere. The name is unconditional.
    public static let showAgentNameKey = "seshctl.showAgentName"

    /// Default — on. Naming the agent costs one short word per row and removes
    /// the need to learn the badge's color/monogram legend.
    public static let showAgentNameDefault = true

    /// Key for the "Show model" toggle. When on, the row subtitle names the
    /// model behind the session next to the agent name.
    public static let showModelKey = "seshctl.showModel"

    /// Default — on. Reading the model is a local transcript scan with no cost,
    /// and it only renders for tools that actually record one (Claude Code
    /// always, Codex when the session emits a `turn_context`).
    public static let showModelDefault = true

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
