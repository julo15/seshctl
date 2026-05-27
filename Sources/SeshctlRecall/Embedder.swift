// Embedder — protocol abstracting the embedding service so tests can
// inject a mock that's instant + cancellation-responsive instead of the
// real CoreML pipeline.
//
// Production conformer: `EmbeddingService` (CoreML + swift-transformers).
// Test conformer: `MockEmbedder` (in Tests/SeshctlRecallTests/), which
// sleeps a configurable interval per chunk and returns dummy vectors —
// the indexer + RecallStack tests use it to exercise timing-sensitive
// paths (cancellation propagation, back-to-back refresh progress) without
// depending on CoreML wall-clock or the bundled model resources.

import Foundation

public protocol Embedder: Actor {
    /// Encode `texts` into L2-unit-normalized embedding vectors. Returns
    /// `[Float]` per input, in caller order. `onProgress(done, total)`
    /// fires once per chunk after that chunk's embeddings land in the
    /// result array.
    ///
    /// Must check `Task.checkCancellation()` between chunks so a canceled
    /// caller (indexer/RecallStack) doesn't continue paying CoreML cost
    /// after the user has moved on.
    ///
    /// Note: Swift protocols can't carry default parameter values. The
    /// concrete `EmbeddingService.encode` documents `batchSize: Int = 64`
    /// but callers going through `any Embedder` must supply it
    /// explicitly. (`Adapter`-style omission won't compile here.)
    func encode(
        _ texts: [String],
        batchSize: Int,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [[Float]]
}

extension EmbeddingService: Embedder {}
