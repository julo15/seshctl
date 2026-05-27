// Search — pure top-K cosine similarity over an in-memory pool of
// L2-unit-normalized vectors.
//
// Why a pure namespace (not an actor or struct with state): the result is
// a deterministic function of inputs, so callers can freely fan out without
// shared mutable state. `RecallStack` is the actor that holds the persistent
// services; this file is the math.
//
// Math: every input vector — both the query and the stored entries — is
// produced by `EmbeddingService`, which L2-normalizes its output. Dot product
// of two unit vectors equals their cosine similarity, so the scoring step is
// just `vDSP_dotpr(query, vector)`.

import Accelerate
import Foundation

public enum Search {
    /// Top-K cosine similarity over in-memory vectors.
    ///
    /// - Parameters:
    ///   - queryVector: the query embedding. Must be L2-unit-normalized.
    ///   - storedIDs: row ids for each stored vector. `storedIDs.count` must
    ///     equal `storedVectors.count`; the function returns ids from this
    ///     array tagged with their score.
    ///   - storedVectors: the candidate pool. Every entry must be the same
    ///     length as `queryVector` and L2-unit-normalized.
    ///   - k: the cap on the number of results. If `k <= 0` or the input is
    ///     empty, returns `[]`. If fewer than `k` candidates exist (or fewer
    ///     than `k` distinct dedup keys when deduping), the smaller count is
    ///     returned.
    ///   - dedupKeys: optional per-vector dedup key. When supplied,
    ///     `dedupKeys.count` must match `storedVectors.count` and only the
    ///     highest-scoring vector per dedupKey value survives. Mirrors the
    ///     Python `recall/search.py` posture of one row per (agent,
    ///     session_id) so a chatty session doesn't crowd out everything else.
    ///
    /// - Returns: `(id, score)` pairs sorted descending by score, capped at
    ///   `k` items.
    // Returns Float (not Double) because vDSP_dotpr operates on Float and we
    // avoid a copy. Callers that need Double convert at the boundary
    // (RecallStack.search does Double(hit.score) when mapping to RecallResult).
    public static func topK(
        queryVector: [Float],
        storedIDs: [Int64],
        storedVectors: [[Float]],
        k: Int,
        dedupKeys: [String]? = nil
    ) -> [(id: Int64, score: Float)] {
        precondition(
            storedIDs.count == storedVectors.count,
            "Search.topK: storedIDs.count (\(storedIDs.count)) != storedVectors.count (\(storedVectors.count))"
        )
        if let dedupKeys {
            precondition(
                dedupKeys.count == storedVectors.count,
                "Search.topK: dedupKeys.count (\(dedupKeys.count)) != storedVectors.count (\(storedVectors.count))"
            )
        }
        guard k > 0, !storedVectors.isEmpty else { return [] }

        let dim = queryVector.count

        // Score every candidate. Both query + stored vectors are unit-norm
        // (EmbeddingService guarantees this), so dot product == cosine sim.
        var scored: [(idx: Int, score: Float)] = []
        scored.reserveCapacity(storedVectors.count)
        queryVector.withUnsafeBufferPointer { qBuf in
            for (idx, vector) in storedVectors.enumerated() {
                // Defensive: skip vectors whose dimension doesn't match the
                // query. Mismatched-dim vectors shouldn't appear in practice
                // (the model always emits the same shape), but a stale row
                // from a previous schema version would otherwise crash vDSP.
                guard vector.count == dim else {
                    AdapterHelpers.warn(
                        "Search: skipped vector with mismatched dim "
                        + "(got \(vector.count), expected \(dim))"
                    )
                    continue
                }
                var dot: Float = 0
                vector.withUnsafeBufferPointer { vBuf in
                    vDSP_dotpr(
                        qBuf.baseAddress!, 1,
                        vBuf.baseAddress!, 1,
                        &dot,
                        vDSP_Length(dim)
                    )
                }
                scored.append((idx: idx, score: dot))
            }
        }

        // Sort descending by score. Stable sort isn't required — ties get
        // broken in arbitrary insertion order, which is fine for top-K UX.
        scored.sort { $0.score > $1.score }

        // Dedup: walk the score-sorted list and keep the first hit per key.
        // The "first" is the highest-scoring by construction.
        let kept: [(idx: Int, score: Float)]
        if let dedupKeys {
            var seen: Set<String> = []
            seen.reserveCapacity(min(k, scored.count))
            var out: [(idx: Int, score: Float)] = []
            out.reserveCapacity(min(k, scored.count))
            for hit in scored {
                let key = dedupKeys[hit.idx]
                if seen.insert(key).inserted {
                    out.append(hit)
                    if out.count == k { break }
                }
            }
            kept = out
        } else {
            kept = Array(scored.prefix(k))
        }

        return kept.map { (id: storedIDs[$0.idx], score: $0.score) }
    }
}
