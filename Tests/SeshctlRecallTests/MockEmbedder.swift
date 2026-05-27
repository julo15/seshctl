// MockEmbedder — test-only Embedder conformer that sleeps a configurable
// interval per chunk and returns deterministic dummy vectors. Used by
// timing-sensitive tests (cancellation propagation, back-to-back refresh
// progress) so they don't depend on CoreML wall-clock or the bundled
// model resources.
//
// The chunk-loop honors `Task.checkCancellation()` so the indexer's
// per-chunk cancellation actually fires within `perChunkDelayNanos` of
// the caller canceling — instead of the real EmbeddingService's
// "in-flight chunk runs to completion" worst case.

import Foundation
@testable import SeshctlRecall

actor MockEmbedder: Embedder {
    private let perChunkDelayNanos: UInt64
    private let vectorDim: Int

    init(perChunkDelayNanos: UInt64 = 20_000_000, vectorDim: Int = 384) {
        self.perChunkDelayNanos = perChunkDelayNanos
        self.vectorDim = vectorDim
    }

    func encode(
        _ texts: [String],
        batchSize: Int,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let total = texts.count
        let chunkSize = max(1, batchSize)

        var results: [[Float]] = []
        results.reserveCapacity(total)

        var index = 0
        while index < total {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: perChunkDelayNanos)
            let upper = min(index + chunkSize, total)
            for _ in index..<upper {
                // Deterministic dummy vector — distinguishable across calls
                // is not needed because the timing-sensitive tests don't
                // assert on vector content.
                results.append([Float](repeating: 0.1, count: vectorDim))
            }
            index = upper
            onProgress?(index, total)
        }
        return results
    }
}
