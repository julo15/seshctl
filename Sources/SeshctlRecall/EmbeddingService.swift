// EmbeddingService — bundled CoreML embedding model + tokenizer wrapper.
//
// Produces 384-dim, L2-unit-norm Float embeddings for arbitrary text using
// the all-MiniLM-L6-v2 model, INT8-quantized + FP32 compute, converted in
// `.agents/spikes/2026-05-25-recall-spike/convert-model.py`. The Phase 1
// parity spike (see the spike README) proved the Swift+CoreML pipeline
// produces top-1 / top-3 agreement of 19/20 and 18/20 respectively against
// the Python recall pipeline; that is the acceptance gate for this service.
//
// Concurrency: `EmbeddingService` is an `actor` — CoreML predict calls are
// serialized per instance.

import Accelerate
import CoreML
import Foundation
import SeshctlCore

// MARK: - Errors.

/// Internal errors surfaced by EmbeddingService construction or inference.
///
/// These are intentionally NOT aliased to `RecallError` — they describe
/// low-level service failures (missing bundle resources, malformed CoreML
/// outputs). `RecallService` translates them at the boundary if/when needed
/// (Phase 6).
public enum EmbeddingServiceError: Error, CustomStringConvertible {
    /// `Bundle.module` could not locate the .mlpackage. Most likely cause:
    /// the model file isn't checked in yet (lands in Phase 7).
    case modelResourceNotFound(String)
    /// `Bundle.module` could not locate the tokenizer folder.
    case tokenizerResourceNotFound(String)
    /// The CoreML model's prediction output didn't expose the expected
    /// feature name (and the fallback "first feature" lookup also failed).
    case missingOutputFeature(String)
    /// The CoreML model's prediction output had an unexpected shape (e.g.
    /// element count != 256 * 384). Surfaces a description of what was seen.
    case unexpectedOutputShape(String)

    public var description: String {
        switch self {
        case let .modelResourceNotFound(detail):
            return "EmbeddingService: model resource not found — \(detail)"
        case let .tokenizerResourceNotFound(detail):
            return "EmbeddingService: tokenizer resource not found — \(detail)"
        case let .missingOutputFeature(name):
            return "EmbeddingService: CoreML output missing expected feature \(name)"
        case let .unexpectedOutputShape(detail):
            return "EmbeddingService: CoreML output had unexpected shape — \(detail)"
        }
    }
}

// MARK: - Service.

public actor EmbeddingService {
    // MARK: - Constants (mirror the Python recall pipeline + the Phase 1 spike).

    private static let maxSequenceLength: Int = 256
    private static let embeddingDimension: Int = 384
    // CoreML feature names — must match what convert-model.py wired up.
    private static let inputIDsFeatureName = "input_ids"
    private static let attentionMaskFeatureName = "attention_mask"
    private static let tokenEmbeddingsFeatureName = "token_embeddings"

    // Production resource lookup constants.
    private static let bundledModelResourceName = "all-MiniLM-L6-v2-int8"
    private static let bundledModelResourceExtension = "mlpackage"
    private static let bundledModelsSubdirectory = "Models"

    // MARK: - Stored state.

    private let model: MLModel
    private let tokenizer: TokenizerService

    // MARK: - Initialization.

    /// Production initializer: loads the bundled model + tokenizer.
    ///
    /// Resource resolution order:
    /// 1. `Bundle.main.resourceURL/Models/` — `.app/Contents/Resources/Models/`.
    ///    `scripts/build-app-bundle.sh` copies the SwiftPM-generated
    ///    `Models/` dir here when assembling the .app, which is the
    ///    conventional macOS app bundle location for resource files.
    /// 2. `Bundle.module/Models/` — SwiftPM-generated bundle. Used by
    ///    `swift test` and dev/CLI flows where there is no .app wrapper.
    ///
    /// The two-step lookup exists because SwiftPM's generated
    /// `Bundle.module` accessor (which expects the bundle at
    /// `Bundle.main.bundleURL/seshctl_SeshctlRecall.bundle`) doesn't
    /// match the standard macOS .app layout (resources live under
    /// `Contents/Resources/`). Trying main.resourceURL first means a
    /// shipped .app doesn't need the SwiftPM-generated bundle at all.
    public init() async throws {
        let modelURL: URL
        let tokenizerFolderURL: URL

        switch Self.resolveBundledResources() {
        case .success(let r):
            modelURL = r.modelURL
            tokenizerFolderURL = r.tokenizerFolderURL
        case .failure(.modelMissing(let detail)):
            throw EmbeddingServiceError.modelResourceNotFound(detail)
        case .failure(.tokenizerMissing(let detail)):
            throw EmbeddingServiceError.tokenizerResourceNotFound(detail)
        }

        let (loadedModel, loadedTokenizer) = try await Self.loadModelAndTokenizer(
            modelURL: modelURL,
            tokenizerFolderURL: tokenizerFolderURL
        )
        self.model = loadedModel
        self.tokenizer = loadedTokenizer
    }

    /// Distinguishes "model missing" from "model found but tokenizer
    /// missing" so the caller can throw the correct
    /// `EmbeddingServiceError` variant. Conforms to `Error` only because
    /// `Swift.Result.Failure` requires it; we never `throw` this type.
    private enum BundledResourcesError: Error {
        case modelMissing(String)
        case tokenizerMissing(String)
    }

    /// Test/dev helper: return the bundled tokenizer folder URL if it can
    /// be resolved, or `nil` otherwise. Goes through the same two-path
    /// fallback as the production initializer (`.app/Contents/Resources/Models/`
    /// then SwiftPM `Bundle.module/Models/`), so tests that only need the
    /// tokenizer folder don't have to duplicate the lookup logic — and
    /// crucially don't fall over when `Bundle.module` is the test target's
    /// bundle (which does not carry `Models/`).
    static func bundledTokenizerFolderURL() -> URL? {
        switch resolveBundledResources() {
        case .success(let r): return r.tokenizerFolderURL
        case .failure: return nil
        }
    }

    /// Locate the bundled `.mlpackage` and tokenizer folder. Returns a
    /// `.failure(.modelMissing)` when neither candidate path has the
    /// model, and `.failure(.tokenizerMissing)` when the model exists but
    /// `tokenizer.json` is not next to it (i.e. the bundle is malformed).
    private static func resolveBundledResources()
        -> Result<(modelURL: URL, tokenizerFolderURL: URL), BundledResourcesError>
    {
        let fm = FileManager.default
        let modelFilename = "\(bundledModelResourceName).\(bundledModelResourceExtension)"

        // 1. .app/Contents/Resources/Models/<model>.mlpackage
        if let resourceURL = Bundle.main.resourceURL {
            let modelsDir = resourceURL.appendingPathComponent(bundledModelsSubdirectory)
            let modelURL = modelsDir.appendingPathComponent(modelFilename)
            if fm.fileExists(atPath: modelURL.path) {
                let tokenizerJSON = modelsDir.appendingPathComponent("tokenizer.json")
                if fm.fileExists(atPath: tokenizerJSON.path) {
                    return .success((modelURL, modelsDir))
                }
                let detail =
                    "model found at \(modelURL.path) but tokenizer.json is "
                    + "missing — expected at \(tokenizerJSON.path). Check "
                    + "that scripts/build-app-bundle.sh copies the whole "
                    + "Models/ folder, not just the .mlpackage."
                return .failure(.tokenizerMissing(detail))
            }
        }

        // 2. SwiftPM Bundle.module/Models/<model>.mlpackage — dev + test path.
        if let modelURL = Bundle.module.url(
            forResource: bundledModelResourceName,
            withExtension: bundledModelResourceExtension,
            subdirectory: bundledModelsSubdirectory
        ) {
            let tokenizerFolderURL = modelURL.deletingLastPathComponent()
            let tokenizerJSON = tokenizerFolderURL.appendingPathComponent("tokenizer.json")
            if fm.fileExists(atPath: tokenizerJSON.path) {
                return .success((modelURL, tokenizerFolderURL))
            }
            let detail =
                "model found at \(modelURL.path) but tokenizer.json is "
                + "missing — expected at \(tokenizerJSON.path). Check that "
                + ".copy(\"Models\") in Package.swift includes tokenizer.json "
                + "alongside the .mlpackage."
            return .failure(.tokenizerMissing(detail))
        }

        let detail =
            "expected Models/\(bundledModelResourceName)"
            + ".\(bundledModelResourceExtension) "
            + "in .app/Contents/Resources/ or SwiftPM Bundle.module — "
            + "check that scripts/build-app-bundle.sh copies Models/ "
            + "and that .copy(\"Models\") is intact in Package.swift"
        return .failure(.modelMissing(detail))
    }

    /// Test/dev initializer: explicit URLs for the .mlpackage and the
    /// tokenizer folder. Used by tests + future scripts that point at the
    /// spike artifacts.
    public init(modelURL: URL, tokenizerFolderURL: URL) async throws {
        let (loadedModel, loadedTokenizer) = try await Self.loadModelAndTokenizer(
            modelURL: modelURL,
            tokenizerFolderURL: tokenizerFolderURL
        )
        self.model = loadedModel
        self.tokenizer = loadedTokenizer
    }

    /// Shared load path used by both initializers. Compiles the .mlpackage,
    /// loads the CoreML model with `cpuOnly`, and constructs the tokenizer.
    private static func loadModelAndTokenizer(
        modelURL: URL,
        tokenizerFolderURL: URL
    ) async throws -> (MLModel, TokenizerService) {
        let compiledURL = try await MLModel.compileModel(at: modelURL)
        let config = MLModelConfiguration()
        // .cpuOnly is forced because the Phase 1 spike observed an MPSGraph
        // assertion failure on the ANE path (computeUnits = .all) for this
        // specific INT8 + MiniLM-L6-v2 + macOS 14 combination. See:
        //   .agents/spikes/2026-05-25-recall-spike/README.md → Findings
        //   .agents/plans/2026-05-25-0055-native-recall-rewrite.md → Phase 3
        // TODO(Phase 10 or later): benchmark `.cpuAndGPU` vs `.cpuAndNeuralEngine`
        // on the production model and revisit the compute-unit choice.
        config.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: compiledURL, configuration: config)
        let tokenizer = try await TokenizerService(tokenizerFolderURL: tokenizerFolderURL)
        return (model, tokenizer)
    }

    // MARK: - Public API.

    /// Encode `texts` to L2-unit-norm 384-dim Float embeddings.
    ///
    /// Per-item shape: each output `[Float]` has exactly `embeddingDimension`
    /// (384) elements and unit L2 norm.
    ///
    /// Batching: the CoreML model has a fixed `[1, 256]` input shape, so
    /// inference is per-item; `batchSize` only controls the frequency of
    /// `onProgress` callbacks. (Future-phase optimization: re-convert the
    /// model with a flexible batch dimension and run one predict per chunk.)
    ///
    /// Progress: `onProgress(done, total)` fires once per chunk after the
    /// chunk finishes. `done` is the cumulative count of items processed;
    /// the final call has `done == total`. If `texts` is empty, the callback
    /// does NOT fire and no CoreML calls are made.
    public func encode(
        _ texts: [String],
        batchSize: Int = 64,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        let total = texts.count
        let chunkSize = max(1, batchSize)

        var results: [[Float]] = []
        results.reserveCapacity(total)

        var index = 0
        while index < total {
            // Cooperative cancellation point. With the indexer's per-chunk
            // pattern (it passes `batchSize: chunk.count`, so this while loop
            // runs exactly once per call), this check effectively bails
            // before kicking off the CoreML pass if the caller has already
            // canceled. For callers that pass a smaller batchSize relative
            // to input, the check also fires between internal chunks.
            try Task.checkCancellation()
            let upper = min(index + chunkSize, total)
            let chunk = Array(texts[index..<upper])
            let tokenized = await tokenizer.encode(chunk)

            for i in 0..<chunk.count {
                let tokenEmbeddings = try Self.runCoreML(
                    model: model,
                    tokenIDs: tokenized.inputIDs[i],
                    attentionMask: tokenized.attentionMask[i]
                )
                let pooled = Self.meanPool(
                    tokenEmbeddings: tokenEmbeddings,
                    attentionMask: tokenized.attentionMask[i]
                )
                let normalized = Self.l2Normalize(pooled)
                results.append(normalized)
            }

            index = upper
            onProgress?(index, total)
        }

        return results
    }

    // MARK: - CoreML inference (copied from the Phase 1 spike, see
    // .agents/spikes/2026-05-25-recall-spike/swift-harness/Sources/SpikeHarness/main.swift).

    private static func runCoreML(
        model: MLModel,
        tokenIDs: [Int32],
        attentionMask: [Int32]
    ) throws -> [Float] {
        let inputIDsArray = try MLMultiArray(
            shape: [1, NSNumber(value: maxSequenceLength)], dataType: .int32
        )
        let attentionMaskArray = try MLMultiArray(
            shape: [1, NSNumber(value: maxSequenceLength)], dataType: .int32
        )

        // Both arrays are dense + contiguous so a straight typed-buffer write is safe.
        let inputIDsPtr = inputIDsArray.dataPointer.assumingMemoryBound(to: Int32.self)
        let attentionMaskPtr = attentionMaskArray.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<maxSequenceLength {
            inputIDsPtr[i] = tokenIDs[i]
            attentionMaskPtr[i] = attentionMask[i]
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputIDsFeatureName: MLFeatureValue(multiArray: inputIDsArray),
            attentionMaskFeatureName: MLFeatureValue(multiArray: attentionMaskArray),
        ])

        let output = try model.prediction(from: provider)
        let tokenEmbeddingsValue: MLFeatureValue
        if let v = output.featureValue(for: tokenEmbeddingsFeatureName) {
            tokenEmbeddingsValue = v
        } else if let firstName = output.featureNames.first,
                  let v = output.featureValue(for: firstName) {
            // CoreML may have renamed the single output — fall back to the only feature.
            tokenEmbeddingsValue = v
        } else {
            throw EmbeddingServiceError.missingOutputFeature(tokenEmbeddingsFeatureName)
        }
        guard let multi = tokenEmbeddingsValue.multiArrayValue else {
            throw EmbeddingServiceError.missingOutputFeature(
                "\(tokenEmbeddingsFeatureName) (not a multiArray)"
            )
        }

        let expectedCount = maxSequenceLength * embeddingDimension
        guard multi.count == expectedCount else {
            throw EmbeddingServiceError.unexpectedOutputShape(
                "expected \(expectedCount) elements ([1, \(maxSequenceLength), "
                + "\(embeddingDimension)]); got \(multi.count) with shape "
                + "\(multi.shape.map { $0.intValue })"
            )
        }

        // Convert to [Float] regardless of underlying dtype. The mlprogram
        // may surface FP16 even when compute_precision=FLOAT32 was set during
        // conversion, so we materialize FP32 here for the Accelerate math.
        var floats = [Float](repeating: 0, count: expectedCount)
        switch multi.dataType {
        case .float32:
            let src = multi.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<expectedCount { floats[i] = src[i] }
        case .float16:
            // CoreML 14+ MLMultiArray surfaces FP16 via `Float16`. Convert in a
            // loop; the cost is negligible at 256 * 384 = 98k elements.
            // `Float16` is unavailable on x86_64 macOS (the universal build
            // compiles for both archs). On Intel Macs we fall through to the
            // `default` MLMultiArray subscript path, which goes through
            // NSNumber and handles every dtype correctly — slower but
            // correct, and Intel Macs are an increasingly small audience.
            #if arch(arm64)
            let src = multi.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<expectedCount { floats[i] = Float(src[i]) }
            #else
            for i in 0..<expectedCount { floats[i] = multi[i].floatValue }
            #endif
        case .double:
            let src = multi.dataPointer.assumingMemoryBound(to: Double.self)
            for i in 0..<expectedCount { floats[i] = Float(src[i]) }
        default:
            // Fall back to subscript indexing for any other dtype.
            for i in 0..<expectedCount { floats[i] = multi[i].floatValue }
        }
        return floats
    }

    // MARK: - Mean pooling over the attention mask.

    /// Mean-pool a `[1, 256, 384]` token-embedding tensor over the attention mask.
    ///
    /// Matches recall/embedding.py:
    ///     mask_expanded = attention_mask[:, :, None]              # (1, 256, 1)
    ///     sum_embeddings = sum(token_embeddings * mask_expanded)  # (1, 384)
    ///     sum_mask = clip(mask_expanded.sum(axis=1), 1e-9)        # (1, 1)
    ///     mean_pooled = sum_embeddings / sum_mask                 # (1, 384)
    private static func meanPool(
        tokenEmbeddings: [Float],
        attentionMask: [Int32]
    ) -> [Float] {
        var sum = [Float](repeating: 0, count: embeddingDimension)
        var maskSum: Float = 0
        for t in 0..<maxSequenceLength {
            guard attentionMask[t] != 0 else { continue }
            maskSum += 1.0
            let rowStart = t * embeddingDimension
            // sum[d] += tokenEmbeddings[rowStart + d]
            tokenEmbeddings.withUnsafeBufferPointer { srcBuf in
                let rowPtr = srcBuf.baseAddress!.advanced(by: rowStart)
                sum.withUnsafeMutableBufferPointer { dstBuf in
                    vDSP_vadd(
                        rowPtr, 1, dstBuf.baseAddress!, 1, dstBuf.baseAddress!, 1,
                        vDSP_Length(embeddingDimension)
                    )
                }
            }
        }
        let denom = max(maskSum, 1e-9)
        var result = [Float](repeating: 0, count: embeddingDimension)
        var inv = 1.0 / denom
        sum.withUnsafeBufferPointer { srcBuf in
            result.withUnsafeMutableBufferPointer { dstBuf in
                vDSP_vsmul(
                    srcBuf.baseAddress!, 1, &inv, dstBuf.baseAddress!, 1,
                    vDSP_Length(embeddingDimension)
                )
            }
        }
        return result
    }

    // MARK: - L2 normalization.

    /// Normalize a 384-vector to unit L2 norm. Matches the `np.linalg.norm` +
    /// `clip(min=1e-9)` divide that recall/embedding.py does.
    private static func l2Normalize(_ vec: [Float]) -> [Float] {
        var dot: Float = 0
        vec.withUnsafeBufferPointer { buf in
            vDSP_dotpr(buf.baseAddress!, 1, buf.baseAddress!, 1, &dot, vDSP_Length(vec.count))
        }
        var norm = sqrtf(dot)
        if norm < 1e-9 { norm = 1e-9 }
        var inv = 1.0 / norm
        var result = [Float](repeating: 0, count: vec.count)
        vec.withUnsafeBufferPointer { srcBuf in
            result.withUnsafeMutableBufferPointer { dstBuf in
                vDSP_vsmul(
                    srcBuf.baseAddress!, 1, &inv, dstBuf.baseAddress!, 1,
                    vDSP_Length(vec.count)
                )
            }
        }
        return result
    }
}
