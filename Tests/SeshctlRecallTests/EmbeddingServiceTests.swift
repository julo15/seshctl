// EmbeddingServiceTests — exercise the production CoreML embedding service
// against the bundled `Sources/SeshctlRecall/Models/` resources. The
// `EmbeddingService()` no-arg init resolves the model + tokenizer via
// `Bundle.module` so these tests run unconditionally on every fresh clone.

import Foundation
import Testing

@testable import SeshctlRecall

// MARK: - Tests.

@Suite("EmbeddingService")
struct EmbeddingServiceTests {
    // 1. Production initializer loads the bundled .mlpackage from
    //    Bundle.module/Models/ — proves the Phase 7 resource pipeline works
    //    end-to-end. If this regresses, check that Sources/SeshctlRecall/
    //    Models/all-MiniLM-L6-v2-int8.mlpackage and the two tokenizer JSONs
    //    are checked in and that Package.swift's .copy("Models") is intact.
    @Test("Production init loads the bundled model successfully")
    func productionInitLoadsBundledModel() async throws {
        _ = try await EmbeddingService()
    }

    // 2. Encode a single string and assert shape + unit norm.
    @Test("Encode produces a 384-dim unit-norm vector")
    func encodeProducesUnitNorm384() async throws {
        let service = try await EmbeddingService()
        let result = try await service.encode(["hello world"])
        #expect(result.count == 1)
        #expect(result[0].count == 384)

        var sumSquares: Float = 0
        for v in result[0] { sumSquares += v * v }
        let norm = sqrtf(sumSquares)
        #expect(abs(norm - 1.0) < 1e-5, "expected unit L2 norm, got \(norm)")
    }

    // 3. Semantically-similar strings should have a high cosine similarity.
    //    Since both vectors are unit-norm, dot product == cosine similarity.
    @Test("Encode produces high cosine similarity for similar strings")
    func encodeSemanticSimilarity() async throws {
        let service = try await EmbeddingService()
        let result = try await service.encode(["hello world", "hello world!"])
        #expect(result.count == 2)
        var dot: Float = 0
        for i in 0..<384 { dot += result[0][i] * result[1][i] }
        #expect(dot > 0.9, "expected cosine similarity > 0.9, got \(dot)")
    }

    // 4. Progress callback fires per chunk. With 5 strings and batchSize=2,
    //    we expect three calls: (2, 5), (4, 5), (5, 5).
    @Test("Encode invokes progress callback per chunk")
    func encodeProgressCallback() async throws {
        let service = try await EmbeddingService()
        let inputs = ["one", "two", "three", "four", "five"]

        // Sendable progress sink — actor-isolated so the @Sendable closure
        // captures it cleanly.
        actor ProgressSink {
            private(set) var calls: [(Int, Int)] = []
            func record(_ done: Int, _ total: Int) { calls.append((done, total)) }
            func snapshot() -> [(Int, Int)] { calls }
        }
        let sink = ProgressSink()

        _ = try await service.encode(inputs, batchSize: 2, onProgress: { done, total in
            Task { await sink.record(done, total) }
        })

        // The Task-dispatch above is async, so wait for them to drain by
        // making one more roundtrip through the actor.
        // Yield a few times to give the captured Tasks a chance to land.
        for _ in 0..<10 {
            await Task.yield()
        }

        let calls = await sink.snapshot()
        #expect(calls.count >= 3, "expected at least 3 progress calls, got \(calls.count): \(calls)")
        // Find the (2,5), (4,5), and (5,5) calls; all must be present.
        #expect(calls.contains(where: { $0.0 == 2 && $0.1 == 5 }), "missing (2, 5) progress call; got \(calls)")
        #expect(calls.contains(where: { $0.0 == 4 && $0.1 == 5 }), "missing (4, 5) progress call; got \(calls)")
        #expect(calls.contains(where: { $0.0 == 5 && $0.1 == 5 }), "missing (5, 5) progress call; got \(calls)")
    }

    // 5. Empty input array short-circuits — no model call, no callback.
    @Test("Encode empty array returns empty result without progress callback")
    func encodeEmptyArray() async throws {
        let service = try await EmbeddingService()
        actor Flag { private(set) var fired = false; func mark() { fired = true } }
        let flag = Flag()
        let result = try await service.encode([], batchSize: 64, onProgress: { _, _ in
            Task { await flag.mark() }
        })
        #expect(result.isEmpty)
        for _ in 0..<5 { await Task.yield() }
        let fired = await flag.fired
        #expect(fired == false, "progress callback should not fire on empty input")
    }
}
