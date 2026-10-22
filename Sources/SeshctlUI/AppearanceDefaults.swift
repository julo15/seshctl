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
    /// Supersedes the `seshctl.stackedRowLayout` boolean, which
    /// `migrateRowLayout` converts once at launch and then deletes.
    public static let rowLayoutKey = "seshctl.rowLayout"

    /// The pre-picker "Stacked row layout" toggle. Read only by
    /// `migrateRowLayout`.
    static let legacyStackedRowLayoutKey = "seshctl.stackedRowLayout"

    /// Default — compact. The stacked and two-column layouts remain for
    /// comparison while compact shakes down; once it sticks, the picker and
    /// the losing code paths should be removed together.
    public static let rowLayoutDefault: RowLayout = .compact

    /// One-shot migration from the pre-release un-prefixed key
    /// (`"repoAccentBarEnabled"`) to `seshctl.repoAccentBarEnabled`.
    /// Run once at app launch so an author who toggled the setting during
    /// dev doesn't silently lose their choice when the key rename ships.
    /// Safe to call repeatedly — no-op after the first successful copy.
    /// One-shot migration from the `seshctl.stackedRowLayout` boolean to the
    /// `seshctl.rowLayout` picker. A saved `false` was a deliberate choice of
    /// the two-column layout, so it carries over as `.twoColumn`. A saved
    /// `true` was the old default (stacked), so it gets the new default,
    /// compact. The old key is removed either way. No-op once the old key
    /// is gone, and never overwrites a value already set in the picker.
    public static func migrateRowLayout(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: legacyStackedRowLayoutKey) != nil else { return }
        if defaults.object(forKey: rowLayoutKey) == nil,
           !defaults.bool(forKey: legacyStackedRowLayoutKey) {
            defaults.set(RowLayout.twoColumn.rawValue, forKey: rowLayoutKey)
        }
        defaults.removeObject(forKey: legacyStackedRowLayoutKey)
    }

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
