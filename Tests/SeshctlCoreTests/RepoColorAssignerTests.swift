import Foundation
import Testing

@testable import SeshctlCore

@Suite("RepoColorAssigner")
struct RepoColorAssignerTests {
    /// Fresh, isolated defaults per test.
    private func makeDefaults() -> UserDefaults {
        let name = "RepoColorAssignerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Slots on a line: distance is just the index difference.
    private func linearDistance(_ a: Int, _ b: Int) -> Double { Double(abs(a - b)) }

    private func makeAssigner(
        slotCount: Int = 12,
        defaults: UserDefaults,
        expiry: TimeInterval = RepoColorAssigner.defaultExpiry
    ) -> RepoColorAssigner {
        RepoColorAssigner(slotCount: slotCount, distance: linearDistance, defaults: defaults, expiry: expiry)
    }

    private func hashSlot(_ name: String, _ count: Int = 12) -> Int {
        RepoColorAssigner.preferredSlot(for: name, slotCount: count)
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Renaming the key would silently drop every saved color.
    @Test("Defaults key is pinned")
    func defaultsKeyPinned() {
        #expect(RepoColorAssigner.defaultsKey == "seshctl.repoColorAssignments")
    }

    @Test("A repo whose hash slot is free gets that slot")
    func usesPreferredSlot() {
        let assigner = makeAssigner(defaults: makeDefaults())
        #expect(assigner.slot(for: "seshctl", now: start) == hashSlot("seshctl"))
    }

    @Test("Two repos with the same hash slot get different slots")
    func resolvesCollision() {
        // The real-world collision that prompted this: both hash to 11.
        #expect(hashSlot("assistant") == hashSlot("qbk-scheduler"))
        let assigner = makeAssigner(defaults: makeDefaults())
        let first = assigner.slot(for: "assistant", now: start)
        let second = assigner.slot(for: "qbk-scheduler", now: start)
        #expect(first == hashSlot("assistant"))
        #expect(second != first)
    }

    @Test("A collision falls back to the free slot farthest from the occupied ones")
    func fallbackMaximizesDistance() {
        let assigner = makeAssigner(defaults: makeDefaults())
        let first = assigner.slot(for: "assistant", now: start)  // slot 11
        let second = assigner.slot(for: "qbk-scheduler", now: start)
        // With linear distance and only slot 11 taken, slot 0 is farthest.
        #expect(first == 11)
        #expect(second == 0)
    }

    @Test("Up to slotCount repos all get distinct slots")
    func distinctUntilFull() {
        let assigner = makeAssigner(defaults: makeDefaults())
        let names = (0..<12).map { "repo-\($0)" }
        let slots = names.map { assigner.slot(for: $0, now: start) }
        #expect(Set(slots).count == 12)
    }

    @Test("Assignments are stable across calls and survive a relaunch")
    func sticky() {
        let defaults = makeDefaults()
        let assigner = makeAssigner(defaults: defaults)
        let a = assigner.slot(for: "assistant", now: start)
        let q = assigner.slot(for: "qbk-scheduler", now: start)

        #expect(assigner.slot(for: "qbk-scheduler", now: start.addingTimeInterval(60)) == q)

        // A fresh instance reading the same defaults, asked in the opposite
        // order, keeps both colors.
        let relaunched = makeAssigner(defaults: defaults)
        #expect(relaunched.slot(for: "qbk-scheduler", now: start.addingTimeInterval(120)) == q)
        #expect(relaunched.slot(for: "assistant", now: start.addingTimeInterval(120)) == a)
    }

    @Test("A repo unseen past the expiry frees its slot")
    func expiryFreesSlot() {
        let expiry: TimeInterval = 10 * 24 * 60 * 60
        let assigner = makeAssigner(defaults: makeDefaults(), expiry: expiry)
        #expect(assigner.slot(for: "assistant", now: start) == 11)

        // qbk-scheduler shows up after assistant has gone stale, so it gets
        // its own hash slot.
        let later = start.addingTimeInterval(expiry + 1)
        #expect(assigner.slot(for: "qbk-scheduler", now: later) == 11)
        // assistant comes back and is reassigned around it.
        #expect(assigner.slot(for: "assistant", now: later) != 11)
    }

    @Test("Seeing a repo keeps its slot from expiring")
    func touchExtendsLease() {
        let expiry: TimeInterval = 10 * 24 * 60 * 60
        let assigner = makeAssigner(defaults: makeDefaults(), expiry: expiry)
        #expect(assigner.slot(for: "assistant", now: start) == 11)
        // Seen again partway through, so it's still live past the original expiry.
        _ = assigner.slot(for: "assistant", now: start.addingTimeInterval(expiry * 0.6))
        let later = start.addingTimeInterval(expiry * 1.2)
        #expect(assigner.slot(for: "qbk-scheduler", now: later) != 11)
        #expect(assigner.slot(for: "assistant", now: later) == 11)
    }

    @Test("With every slot taken, a new repo shares the least recently seen slot")
    func fullPaletteSharesOldest() {
        let assigner = makeAssigner(slotCount: 3, defaults: makeDefaults())
        let oldest = assigner.slot(for: "a", now: start)
        _ = assigner.slot(for: "b", now: start.addingTimeInterval(100))
        _ = assigner.slot(for: "c", now: start.addingTimeInterval(200))
        #expect(assigner.slot(for: "d", now: start.addingTimeInterval(300)) == oldest)
    }

    @Test("Saved slots out of range after a palette shrink are reassigned")
    func dropsOutOfRangeSlots() {
        let defaults = makeDefaults()
        let wide = makeAssigner(slotCount: 12, defaults: defaults)
        #expect(wide.slot(for: "assistant", now: start) == 11)

        let narrow = makeAssigner(slotCount: 4, defaults: defaults)
        #expect((0..<4).contains(narrow.slot(for: "assistant", now: start)))
    }

    // MARK: - Throttle, tie-break, corrupt data, peek, full-palette share

    private func storedLastSeen(_ name: String, in defaults: UserDefaults) throws -> Date {
        let data = try #require(defaults.data(forKey: RepoColorAssigner.defaultsKey))
        let decoded = try JSONDecoder().decode([String: RepoColorAssigner.Assignment].self, from: data)
        return try #require(decoded[name]).lastSeen
    }

    /// A name other than `name` whose preferred slot is the same.
    private func collidingName(with name: String, slotCount: Int = 12) -> String {
        let target = hashSlot(name, slotCount)
        return (0...).lazy.map { "collide-\($0)" }.first { $0 != name && hashSlot($0, slotCount) == target }!
    }

    @Test("lastSeen is rewritten at most once per touch interval")
    func touchThrottle() throws {
        let defaults = makeDefaults()
        let assigner = makeAssigner(defaults: defaults)
        _ = assigner.slot(for: "assistant", now: start)

        _ = assigner.slot(for: "assistant", now: start.addingTimeInterval(23 * 60 * 60))
        #expect(try storedLastSeen("assistant", in: defaults) == start)

        let dayLater = start.addingTimeInterval(RepoColorAssigner.touchInterval)
        _ = assigner.slot(for: "assistant", now: dayLater)
        #expect(try storedLastSeen("assistant", in: defaults) == dayLater)
    }

    @Test("Equally distant free slots go to the first one after the preferred slot")
    func tieBreakFollowsPreferred() {
        let constant: @Sendable (Int, Int) -> Double = { _, _ in 1 }
        let assigner = RepoColorAssigner(slotCount: 12, distance: constant, defaults: makeDefaults())
        _ = assigner.slot(for: "seshctl", now: start)
        let preferred = hashSlot("seshctl")
        #expect(assigner.slot(for: collidingName(with: "seshctl"), now: start) == (preferred + 1) % 12)
    }

    @Test("The tie-break wraps past the last slot")
    func tieBreakWraps() {
        let constant: @Sendable (Int, Int) -> Double = { _, _ in 1 }
        let assigner = RepoColorAssigner(slotCount: 12, distance: constant, defaults: makeDefaults())
        #expect(assigner.slot(for: "assistant", now: start) == 11)
        #expect(assigner.slot(for: "qbk-scheduler", now: start) == 0)
    }

    @Test("Unreadable saved data is discarded, not fatal")
    func corruptDefaults() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: RepoColorAssigner.defaultsKey)
        let assigner = makeAssigner(defaults: defaults)
        #expect(assigner.slot(for: "assistant", now: start) == 11)
    }

    @Test("peekSlot returns a saved slot without claiming one for new names")
    func peekDoesNotClaim() {
        let defaults = makeDefaults()
        let assigner = makeAssigner(defaults: defaults)
        let assistant = assigner.slot(for: "assistant", now: start)

        // Saved slot comes back as-is.
        #expect(assigner.peekSlot(for: "assistant", now: start) == assistant)
        // An unsaved name gets its hash slot even though that slot is taken...
        #expect(assigner.peekSlot(for: "qbk-scheduler", now: start) == hashSlot("qbk-scheduler"))
        // ...and nothing was saved, so a later claim still avoids the collision.
        #expect(assigner.slot(for: "qbk-scheduler", now: start) != assistant)
    }

    @Test("peekSlot ignores an expired assignment")
    func peekIgnoresExpired() {
        let expiry: TimeInterval = 60
        let assigner = makeAssigner(defaults: makeDefaults(), expiry: expiry)
        _ = assigner.slot(for: "assistant", now: start)
        _ = assigner.slot(for: "qbk-scheduler", now: start)  // moved off 11
        #expect(assigner.peekSlot(for: "qbk-scheduler", now: start.addingTimeInterval(expiry + 1)) == 11)
    }

    @Test("With every slot taken, the slot with the fewest holders wins over the oldest")
    func fullPalettePrefersFewestHolders() {
        let assigner = makeAssigner(slotCount: 2, defaults: makeDefaults())
        let a = assigner.slot(for: "a", now: start)
        let b = assigner.slot(for: "b", now: start.addingTimeInterval(1000))
        #expect(a != b)
        // c shares a's slot (both slots have one holder; a's is older).
        #expect(assigner.slot(for: "c", now: start.addingTimeInterval(1)) == a)
        // a's slot now has two holders, b's one, so d shares b's slot even
        // though b was seen more recently.
        #expect(assigner.slot(for: "d", now: start.addingTimeInterval(2000)) == b)
    }
}
