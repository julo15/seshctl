// EmbeddingServiceTests — cover the production lazy-load failure path and,
// when the Phase 1 spike's locally-built .mlpackage is present, exercise the
// real CoreML inference path end-to-end against it.

import Foundation
import Testing

@testable import SeshctlRecall

// MARK: - Test helpers.

/// Walks up from this source file to find the repo root (the directory
/// containing `Package.swift`). Same pattern as `Tests/SeshctlCoreTests/`.
private func repoRoot() -> URL {
    var url = URL(fileURLWithPath: #file)
    while url.path != "/" {
        url = url.deletingLastPathComponent()
        let candidate = url.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return url
        }
    }
    fatalError("could not find Package.swift walking up from \(#file)")
}

/// URLs to the Phase 1 spike's locally-generated CoreML model + tokenizer.
/// These are NOT checked into git (the .mlpackage is multiple MB and the
/// repo's .gitignore excludes the spike's artifacts), so tests that depend
/// on them must skip gracefully when they're absent (e.g. on CI).
private struct SpikeArtifacts {
    let modelURL: URL
    let tokenizerFolderURL: URL

    static func resolveIfAvailable() -> SpikeArtifacts? {
        let root = repoRoot()
        let spikeDir = root
            .appendingPathComponent(".agents/spikes/2026-05-25-recall-spike")
        let modelURL = spikeDir
            .appendingPathComponent("all-MiniLM-L6-v2-int8.mlpackage")
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelURL.path) else { return nil }
        guard fm.fileExists(atPath: spikeDir.appendingPathComponent("tokenizer.json").path),
              fm.fileExists(atPath: spikeDir.appendingPathComponent("tokenizer_config.json").path)
        else { return nil }
        return SpikeArtifacts(modelURL: modelURL, tokenizerFolderURL: spikeDir)
    }
}

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

    // 2. The explicit-URL initializer should succeed against the spike's
    //    artifacts. This is the smoke test that the lazy-load + CoreML
    //    compile path actually works end-to-end.
    @Test("Init with spike artifacts succeeds")
    func initWithSpikeArtifactsSucceeds() async throws {
        guard let artifacts = SpikeArtifacts.resolveIfAvailable() else {
            // Spike artifacts not present (e.g. fresh clone, CI). Skip.
            return
        }
        _ = try await EmbeddingService(
            modelURL: artifacts.modelURL,
            tokenizerFolderURL: artifacts.tokenizerFolderURL
        )
    }

    // 3. Encode a single string and assert shape + unit norm.
    @Test("Encode produces a 384-dim unit-norm vector")
    func encodeProducesUnitNorm384() async throws {
        guard let artifacts = SpikeArtifacts.resolveIfAvailable() else { return }
        let service = try await EmbeddingService(
            modelURL: artifacts.modelURL,
            tokenizerFolderURL: artifacts.tokenizerFolderURL
        )
        let result = try await service.encode(["hello world"])
        #expect(result.count == 1)
        #expect(result[0].count == 384)

        var sumSquares: Float = 0
        for v in result[0] { sumSquares += v * v }
        let norm = sqrtf(sumSquares)
        #expect(abs(norm - 1.0) < 1e-5, "expected unit L2 norm, got \(norm)")
    }

    // 4. Semantically-similar strings should have a high cosine similarity.
    //    Since both vectors are unit-norm, dot product == cosine similarity.
    @Test("Encode produces high cosine similarity for similar strings")
    func encodeSemanticSimilarity() async throws {
        guard let artifacts = SpikeArtifacts.resolveIfAvailable() else { return }
        let service = try await EmbeddingService(
            modelURL: artifacts.modelURL,
            tokenizerFolderURL: artifacts.tokenizerFolderURL
        )
        let result = try await service.encode(["hello world", "hello world!"])
        #expect(result.count == 2)
        var dot: Float = 0
        for i in 0..<384 { dot += result[0][i] * result[1][i] }
        #expect(dot > 0.9, "expected cosine similarity > 0.9, got \(dot)")
    }

    // 5. Progress callback fires per chunk. With 5 strings and batchSize=2,
    //    we expect three calls: (2, 5), (4, 5), (5, 5).
    @Test("Encode invokes progress callback per chunk")
    func encodeProgressCallback() async throws {
        guard let artifacts = SpikeArtifacts.resolveIfAvailable() else { return }
        let service = try await EmbeddingService(
            modelURL: artifacts.modelURL,
            tokenizerFolderURL: artifacts.tokenizerFolderURL
        )
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

    // 6. Empty input array short-circuits — no model call, no callback.
    @Test("Encode empty array returns empty result without progress callback")
    func encodeEmptyArray() async throws {
        guard let artifacts = SpikeArtifacts.resolveIfAvailable() else { return }
        let service = try await EmbeddingService(
            modelURL: artifacts.modelURL,
            tokenizerFolderURL: artifacts.tokenizerFolderURL
        )
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
