// SearchTests — pure top-K cosine similarity.
//
// All fixtures here are L2-unit-normalized by hand so the math matches what
// Search.topK assumes about its inputs. Vectors are tiny (3-dim) to keep
// the arithmetic auditable.

import Foundation
import Testing

@testable import SeshctlRecall

// MARK: - Helpers.

/// Build a unit-norm vector from raw components. Vectors here are tiny so
/// the per-test cost of normalizing is irrelevant.
private func unit(_ components: [Float]) -> [Float] {
    let magnitude = sqrtf(components.reduce(0) { $0 + $1 * $1 })
    precondition(magnitude > 0, "unit(): zero-magnitude input")
    return components.map { $0 / magnitude }
}

@Suite("Search")
struct SearchTests {
    @Test("topK returns exactly k items when more candidates than k")
    func returnsKItems() {
        // 10 vectors, all distinct angles in 3D. k=3 → exactly 3 results.
        let stored: [[Float]] = (0..<10).map { i in
            unit([Float(i + 1), Float(10 - i), 1])
        }
        let ids: [Int64] = (0..<10).map { Int64($0) }
        let query = unit([1, 0, 0])

        let hits = Search.topK(
            queryVector: query,
            storedIDs: ids,
            storedVectors: stored,
            k: 3
        )

        #expect(hits.count == 3)
    }

    @Test("topK scores are sorted descending")
    func scoresSortedDescending() {
        let stored: [[Float]] = [
            unit([1, 0, 0]),    // dot with query = 1.0
            unit([0.9, 0.1, 0]),
            unit([0.5, 0.5, 0]),
            unit([0, 1, 0]),    // dot with query = 0
            unit([0.7, 0.3, 0]),
        ]
        let ids: [Int64] = [10, 11, 12, 13, 14]
        let query = unit([1, 0, 0])

        let hits = Search.topK(
            queryVector: query,
            storedIDs: ids,
            storedVectors: stored,
            k: 5
        )

        #expect(hits.count == 5)
        for i in 1..<hits.count {
            #expect(hits[i - 1].score >= hits[i].score)
        }
        // Sanity: best match is the first vector (dot product == 1.0).
        #expect(hits.first?.id == 10)
    }

    @Test("topK with dedupKeys keeps only the highest-scoring entry per key")
    func dedupByKey() {
        // 10 vectors paired into 5 dedup buckets (two per key). Score order
        // is deliberately interleaved so dedup has to keep the better of
        // each pair, not just the first encountered.
        // Each pair: (better-score vector, worse-score vector).
        let stored: [[Float]] = [
            unit([1.0, 0.0, 0.0]),   // key "A" — best
            unit([0.3, 0.7, 0.0]),   // key "A" — worse
            unit([0.95, 0.05, 0.0]), // key "B" — best
            unit([0.2, 0.8, 0.0]),   // key "B" — worse
            unit([0.9, 0.1, 0.0]),   // key "C" — best
            unit([0.1, 0.9, 0.0]),   // key "C" — worse
            unit([0.85, 0.15, 0.0]), // key "D" — best
            unit([0.05, 0.95, 0.0]), // key "D" — worse
            unit([0.8, 0.2, 0.0]),   // key "E" — best
            unit([0.0, 1.0, 0.0]),   // key "E" — worse
        ]
        let ids: [Int64] = (0..<10).map { Int64(100 + $0) }
        let dedupKeys = ["A", "A", "B", "B", "C", "C", "D", "D", "E", "E"]
        let query = unit([1, 0, 0])

        let hits = Search.topK(
            queryVector: query,
            storedIDs: ids,
            storedVectors: stored,
            k: 10,
            dedupKeys: dedupKeys
        )

        #expect(hits.count == 5)
        // Confirm the surviving ids are the "best per key" (even-indexed
        // entries 100, 102, 104, 106, 108).
        let keptIDs = Set(hits.map(\.id))
        #expect(keptIDs == Set<Int64>([100, 102, 104, 106, 108]))
    }

    @Test("topK on an empty candidate pool returns an empty array")
    func emptyInputReturnsEmpty() {
        let query = unit([1, 0, 0])
        let hits = Search.topK(
            queryVector: query,
            storedIDs: [],
            storedVectors: [],
            k: 5
        )
        #expect(hits.isEmpty)
    }

    @Test("topK with fewer candidates than k returns all candidates")
    func fewerCandidatesThanK() {
        let stored: [[Float]] = [
            unit([1, 0, 0]),
            unit([0.5, 0.5, 0]),
            unit([0, 1, 0]),
        ]
        let ids: [Int64] = [1, 2, 3]
        let query = unit([1, 0, 0])

        let hits = Search.topK(
            queryVector: query,
            storedIDs: ids,
            storedVectors: stored,
            k: 10
        )

        #expect(hits.count == 3)
        // Best-to-worst order is preserved.
        #expect(hits.map(\.id) == [1, 2, 3])
    }
}
