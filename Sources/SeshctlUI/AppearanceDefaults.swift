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

    /// Key for the "Row layout" picker. Stores a `RowLayout` raw value.
    /// Supersedes the earlier `seshctl.stackedRowLayout` boolean, which is
    /// no longer read — everyone lands on the compact default once.
    public static let rowLayoutKey = "seshctl.rowLayout"

    /// Default — compact. The stacked and two-column layouts remain for
    /// comparison while compact shakes down; once it sticks, the picker and
    /// the losing code paths should be removed together.
    public static let rowLayoutDefault: RowLayout = .compact

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

/// Session row layouts selectable from Settings → Appearance.
public enum RowLayout: String, CaseIterable, Sendable {
    /// One line per row — title, repo-colored folder label, faded message.
    /// The selected row expands to show the message on its own lines.
    case compact
    /// Repo name, branch/title and message stacked across the full width.
    case stacked
    /// Repo name and branch/title in a fixed 180pt left column, message on
    /// the right.
    case twoColumn

    public var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .stacked: return "Stacked"
        case .twoColumn: return "Two-column"
        }
    }
}
