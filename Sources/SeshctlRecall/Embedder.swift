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

/// Defers building the real embedder until the first `encode`. Keyword
/// search shares `RecallStack` with semantic search but never embeds, so it
/// shouldn't pay the CoreML model load.
actor LazyEmbedder: Embedder {
    private let make: @Sendable () async throws -> any Embedder
    private var loading: Task<any Embedder, Error>?

    init(_ make: @escaping @Sendable () async throws -> any Embedder) {
        self.make = make
    }

    func encode(
        _ texts: [String],
        batchSize: Int,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [[Float]] {
        let embedder = try await resolve()
        return try await embedder.encode(texts, batchSize: batchSize, onProgress: onProgress)
    }

    /// Concurrent first calls share one load. A failed load is retried on
    /// the next call.
    private func resolve() async throws -> any Embedder {
        if let loading {
            return try await loading.value
        }
        let make = self.make
        let task = Task { try await make() }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil
            throw error
        }
    }
}
