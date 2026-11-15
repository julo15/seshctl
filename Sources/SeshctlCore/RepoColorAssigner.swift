import Foundation

/// Assigns each repo a palette slot that no other recently seen repo holds,
/// and remembers the choice so a repo keeps its color.
///
/// **Why not just `hash % count`.** Hashing picks each repo's slot without
/// looking at any other repo, so collisions follow the birthday problem: with
/// 12 slots, 4 repos share a color ~40% of the time and 6 repos ~78%. No
/// palette size fixes that while staying distinguishable. Here the hash is
/// only the *preferred* slot: a repo takes it when it's free, and otherwise
/// takes the free slot that looks most different from the slots in use.
///
/// **Sticky.** An assignment is saved the first time a repo is seen and never
/// moves while the repo stays in use, so colors don't reshuffle as repos come
/// and go from the list. A repo unseen for `expiry` gives up its slot; if it
/// comes back it's assigned afresh, which usually lands on its hash slot again.
///
/// If every slot is held by an active repo, a new repo shares the slot whose
/// holders were seen least recently.
public final class RepoColorAssigner: @unchecked Sendable {
    struct Assignment: Codable, Equatable {
        var slot: Int
        var lastSeen: Date
    }

    public static let defaultsKey = "seshctl.repoColorAssignments"

    /// How long a repo keeps its slot without being seen.
    public static let defaultExpiry: TimeInterval = 30 * 24 * 60 * 60

    /// `lastSeen` is rewritten at most this often, so rendering a row doesn't
    /// write UserDefaults on every frame.
    static let touchInterval: TimeInterval = 24 * 60 * 60

    private let slotCount: Int
    private let distance: (Int, Int) -> Double
    private let defaults: UserDefaults
    private let expiry: TimeInterval
    private let lock = NSLock()
    private var assignments: [String: Assignment]

    /// - Parameter distance: how different two slots look (larger = more
    ///   different). Used to pick a fallback slot when the preferred one is taken.
    public init(
        slotCount: Int,
        distance: @escaping (Int, Int) -> Double,
        defaults: UserDefaults = .standard,
        expiry: TimeInterval = RepoColorAssigner.defaultExpiry
    ) {
        precondition(slotCount > 0)
        self.slotCount = slotCount
        self.distance = distance
        self.defaults = defaults
        self.expiry = expiry
        self.assignments = Self.load(from: defaults, slotCount: slotCount)
    }

    public func slot(for name: String, now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }

        if var existing = assignments[name], now.timeIntervalSince(existing.lastSeen) < expiry {
            if now.timeIntervalSince(existing.lastSeen) >= Self.touchInterval {
                existing.lastSeen = now
                assignments[name] = existing
                save()
            }
            return existing.slot
        }

        // Drop expired entries (including this name's, if stale) so their
        // slots count as free.
        assignments = assignments.filter { now.timeIntervalSince($0.value.lastSeen) < expiry }

        let slot = chooseSlot(for: name)
        assignments[name] = Assignment(slot: slot, lastSeen: now)
        save()
        return slot
    }

    private func chooseSlot(for name: String) -> Int {
        let preferred = Int(StableHash.djb2(name) % UInt64(slotCount))
        let occupied = Set(assignments.values.map(\.slot))
        if !occupied.contains(preferred) { return preferred }

        let free = (0..<slotCount).filter { !occupied.contains($0) }
        if !free.isEmpty {
            // The free slot farthest from its nearest occupied slot. Ties go
            // to the slot closest after `preferred`, so the choice is stable.
            func score(_ slot: Int) -> Double {
                occupied.map { distance(slot, $0) }.min() ?? .infinity
            }
            func order(_ slot: Int) -> Int { (slot - preferred + slotCount) % slotCount }
            return free.max { a, b in
                let sa = score(a), sb = score(b)
                return sa != sb ? sa < sb : order(a) > order(b)
            }!
        }

        // Every slot is in use: share the one whose holders were seen longest ago.
        var newestSeen: [Int: Date] = [:]
        for assignment in assignments.values {
            newestSeen[assignment.slot] = max(newestSeen[assignment.slot] ?? .distantPast, assignment.lastSeen)
        }
        return newestSeen.min { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }!.key
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(assignments) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults, slotCount: Int) -> [String: Assignment] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Assignment].self, from: data) else {
            return [:]
        }
        // A palette resize can leave slots out of range; reassign those.
        return decoded.filter { (0..<slotCount).contains($0.value.slot) }
    }
}
