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
//
// ## Intentional semantic differences vs. production `EmbeddingService`
//
// - **Cancellation is doubly responsive.** Both `Task.checkCancellation()`
//   AND `Task.sleep(...)` honor cancellation. The real `EmbeddingService`
//   only checks at chunk boundaries; mid-chunk CoreML.prediction is
//   uninterruptible. Don't write "cancel latency ≤ X ms" tests against
//   the mock — they'd be too generous to translate to production.
//
// - **Output vectors are all `0.1`, NOT L2-unit-normalized** (norm ≈ 1.96).
//   `Search.topK` documents but does not `precondition`-check unit-norm,
//   and with all-equal vectors every cosine dot product is identical.
//   That's fine for `entryCount`/progress-event assertions but would
//   make any "expect top result is X" assertion non-deterministic.
//   **MockEmbedder is timing-only — for content-assertion tests, use
//   the real `EmbeddingService()` (the existing `endToEnd…` test does
//   this).**

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

        // Hoisted constant — every text gets the same dummy vector. See the
        // file-level doc comment about the (intentional) non-unit-norm.
        let dummyVector = [Float](repeating: 0.1, count: vectorDim)

        var index = 0
        while index < total {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: perChunkDelayNanos)
            let upper = min(index + chunkSize, total)
            for _ in index..<upper {
                results.append(dummyVector)
            }
            index = upper
            onProgress?(index, total)
        }
        return results
    }
}
