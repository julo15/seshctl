import Foundation
import Testing

@testable import SeshctlUI

@Suite("AppearanceDefaults.migrateRowLayout")
struct RowLayoutMigrationTests {

    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "seshctl.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("a saved two-column choice (false) carries over and the old key is removed")
    func twoColumnCarriesOver() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AppearanceDefaults.legacyStackedRowLayoutKey)

        AppearanceDefaults.migrateRowLayout(defaults: defaults)

        #expect(defaults.string(forKey: AppearanceDefaults.rowLayoutKey) == RowLayout.twoColumn.rawValue)
        #expect(defaults.object(forKey: AppearanceDefaults.legacyStackedRowLayoutKey) == nil)
    }

    @Test("the old stacked default (true) lands on the new default and the old key is removed")
    func stackedGetsNewDefault() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppearanceDefaults.legacyStackedRowLayoutKey)

        AppearanceDefaults.migrateRowLayout(defaults: defaults)

        #expect(defaults.object(forKey: AppearanceDefaults.rowLayoutKey) == nil)
        #expect(defaults.object(forKey: AppearanceDefaults.legacyStackedRowLayoutKey) == nil)
    }

    @Test("an existing picker value is never overwritten")
    func keepsExistingPickerValue() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(RowLayout.stacked.rawValue, forKey: AppearanceDefaults.rowLayoutKey)
        defaults.set(false, forKey: AppearanceDefaults.legacyStackedRowLayoutKey)

        AppearanceDefaults.migrateRowLayout(defaults: defaults)

        #expect(defaults.string(forKey: AppearanceDefaults.rowLayoutKey) == RowLayout.stacked.rawValue)
        #expect(defaults.object(forKey: AppearanceDefaults.legacyStackedRowLayoutKey) == nil)
    }

    @Test("no old key is a no-op")
    func noOldKey() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        AppearanceDefaults.migrateRowLayout(defaults: defaults)

        #expect(defaults.object(forKey: AppearanceDefaults.rowLayoutKey) == nil)
    }
}

@Suite("RowLayout")
struct RowLayoutTests {

    /// Raw values are persisted in UserDefaults; renaming one silently
    /// resets every user who picked it.
    @Test("persisted raw values are stable")
    func rawValues() {
        #expect(RowLayout.compact.rawValue == "compact")
        #expect(RowLayout.stacked.rawValue == "stacked")
        #expect(RowLayout.twoColumn.rawValue == "twoColumn")
    }

    @Test("an unknown stored value doesn't decode")
    func unknownRawValue() {
        #expect(RowLayout(rawValue: "grid") == nil)
    }
}

@Suite("RowLayout.clickAction")
struct RowClickActionTests {
    @Test("Compact: a click on an unselected row selects it, so its message expands")
    func compactSelectsFirst() {
        #expect(RowLayout.compact.clickAction(rowIsSelected: false) == .select)
    }

    @Test("Compact: a click on the selected row opens it")
    func compactOpensSelected() {
        #expect(RowLayout.compact.clickAction(rowIsSelected: true) == .open)
    }

    @Test("Stacked and two-column don't collapse, so one click opens", arguments: [RowLayout.stacked, .twoColumn])
    func nonCompactOpensImmediately(layout: RowLayout) {
        #expect(layout.clickAction(rowIsSelected: false) == .open)
        #expect(layout.clickAction(rowIsSelected: true) == .open)
    }
}
