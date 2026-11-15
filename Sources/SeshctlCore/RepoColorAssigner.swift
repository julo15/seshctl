import Foundation
import os

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
/// If every slot is held by an active repo, a new repo shares the slot with
/// the fewest holders, breaking ties by the least recently seen.
///
/// `@unchecked Sendable`: all mutable state (`assignments`) is guarded by `lock`.
public final class RepoColorAssigner: @unchecked Sendable {
    struct Assignment: Codable, Equatable {
        var slot: Int
        var lastSeen: Date
    }

    static let defaultsKey = "seshctl.repoColorAssignments"

    /// How long a repo keeps its slot without being seen.
    public static let defaultExpiry: TimeInterval = 30 * 24 * 60 * 60

    /// `lastSeen` is rewritten at most this often, so rendering a row doesn't
    /// write UserDefaults on every frame.
    static let touchInterval: TimeInterval = 24 * 60 * 60

    private let slotCount: Int
    private let distance: @Sendable (Int, Int) -> Double
    private let defaults: UserDefaults
    private let expiry: TimeInterval
    private let lock = NSLock()
    private var assignments: [String: Assignment]

    /// - Parameter distance: how different two slots look (larger = more
    ///   different). Used to pick a fallback slot when the preferred one is taken.
    public init(
        slotCount: Int,
        distance: @escaping @Sendable (Int, Int) -> Double,
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

    /// The repo's color without claiming a slot: its saved slot if it has a
    /// live one, otherwise its preferred slot. Never writes. For surfaces that
    /// show many repos the user isn't working in (History search results),
    /// which would otherwise fill the palette.
    public func peekSlot(for name: String, now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let existing = assignments[name], now.timeIntervalSince(existing.lastSeen) < expiry {
            return existing.slot
        }
        return Self.preferredSlot(for: name, slotCount: slotCount)
    }

    private func chooseSlot(for name: String) -> Int {
        let preferred = Self.preferredSlot(for: name, slotCount: slotCount)
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

        // Every slot is in use: share the one with the fewest holders, then
        // the one whose holders were seen longest ago. Holder count comes
        // first because `lastSeen` is only refreshed daily, so a repo in use
        // all day can look up to 24h stale.
        var holders: [Int: (count: Int, newestSeen: Date)] = [:]
        for assignment in assignments.values {
            let current = holders[assignment.slot] ?? (0, .distantPast)
            holders[assignment.slot] = (current.count + 1, max(current.newestSeen, assignment.lastSeen))
        }
        return holders.min { a, b in
            if a.value.count != b.value.count { return a.value.count < b.value.count }
            if a.value.newestSeen != b.value.newestSeen { return a.value.newestSeen < b.value.newestSeen }
            return a.key < b.key
        }!.key
    }

    /// The slot a repo gets when nothing else holds it.
    static func preferredSlot(for name: String, slotCount: Int) -> Int {
        Int(StableHash.djb2(name) % UInt64(slotCount))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(assignments) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults, slotCount: Int) -> [String: Assignment] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        let decoded: [String: Assignment]
        do {
            decoded = try JSONDecoder().decode([String: Assignment].self, from: data)
        } catch {
            repoColorLogger.error("Discarding unreadable repo color assignments: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
        // A palette resize can leave slots out of range; reassign those.
        return decoded.filter { (0..<slotCount).contains($0.value.slot) }
    }
}

fileprivate let repoColorLogger = Logger(subsystem: "app.seshctl", category: "repo-colors")
