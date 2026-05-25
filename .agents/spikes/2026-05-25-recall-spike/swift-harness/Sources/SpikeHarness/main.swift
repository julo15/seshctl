// SpikeHarness — Phase 1 parity-spike CLI.
//
// Tokenizes a list of reference strings via huggingface/swift-transformers,
// runs the INT8 CoreML embedding model, applies mean-pool over the attention
// mask, L2-normalizes via Accelerate, and writes a JSON array of records
// matching the schema produced by dump-python-reference.py. compare-parity.py
// then diffs the two files and enforces the parity gate.
//
// Usage:
//   SpikeHarness <model.mlpackage> <tokenizer-folder> <reference-strings.txt> [output.json]
//
// `<tokenizer-folder>` is a directory containing tokenizer.json AND
// tokenizer_config.json — both are required by AutoTokenizer.from(modelFolder:).
// `<output.json>` defaults to ./swift-output.json.

import Accelerate
import CoreML
import Foundation
import Tokenizers

// MARK: - Constants matching the Python pipeline.

private let maxSequenceLength: Int = 256
private let embeddingDimension: Int = 384
private let padTokenId: Int32 = 0
// The CoreML model exposes its inputs/outputs under these names — must match
// what convert-model.py wired up. Outputs default to "token_embeddings" but
// CoreML may rename if collisions occur; we read by index as a fallback.
private let inputIDsFeatureName = "input_ids"
private let attentionMaskFeatureName = "attention_mask"
private let tokenEmbeddingsFeatureName = "token_embeddings"

// MARK: - Output record schema. Must mirror python-reference.json exactly.

private struct OutputRecord: Encodable {
    let input: String
    let token_ids: [Int32]
    let attention_mask: [Int32]
    let embedding: [Float]
}

// MARK: - Top-level entry point.

@main
struct SpikeHarness {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            FileHandle.standardError.write(Data((
                "Usage: \(args.first ?? "SpikeHarness") "
                + "<model.mlpackage> <tokenizer-folder> "
                + "<reference-strings.txt> [output.json]\n"
            ).utf8))
            exit(2)
        }
        let modelURL = URL(fileURLWithPath: args[1])
        let tokenizerFolderURL = URL(fileURLWithPath: args[2])
        let referenceStringsURL = URL(fileURLWithPath: args[3])
        let outputURL = URL(fileURLWithPath: args.count >= 5 ? args[4] : "swift-output.json")

        do {
            let referenceStrings = try readReferenceStrings(at: referenceStringsURL)
            FileHandle.standardError.write(Data((
                ">> Loaded \(referenceStrings.count) reference strings\n"
            ).utf8))

            FileHandle.standardError.write(Data(">> Loading tokenizer\n".utf8))
            let tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerFolderURL)

            FileHandle.standardError.write(Data(">> Compiling + loading CoreML model\n".utf8))
            let compiledURL = try await MLModel.compileModel(at: modelURL)
            let modelConfig = MLModelConfiguration()
            // Spike parity test: force CPU. .all (ANE/GPU) crashes MPSGraph on this
            // macOS 14 + MiniLM-L6-v2 + INT8-quant combination. Production may want
            // a different compute unit; revisit after parity is proven.
            modelConfig.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: compiledURL, configuration: modelConfig)

            var records: [OutputRecord] = []
            records.reserveCapacity(referenceStrings.count)

            for (idx, text) in referenceStrings.enumerated() {
                let (tokenIDs, attentionMask) = try tokenizeAndPad(
                    text: text,
                    tokenizer: tokenizer
                )
                let tokenEmbeddings = try runCoreML(
                    model: model,
                    tokenIDs: tokenIDs,
                    attentionMask: attentionMask
                )
                let pooled = meanPool(
                    tokenEmbeddings: tokenEmbeddings,
                    attentionMask: attentionMask
                )
                let normalized = l2Normalize(pooled)

                records.append(OutputRecord(
                    input: text,
                    token_ids: tokenIDs,
                    attention_mask: attentionMask,
                    embedding: normalized
                ))
                FileHandle.standardError.write(Data((
                    ">> [\(idx + 1)/\(referenceStrings.count)] encoded\n"
                ).utf8))
            }

            try writeJSON(records: records, to: outputURL)
            FileHandle.standardError.write(Data((
                ">> Wrote \(records.count) records to \(outputURL.path)\n"
            ).utf8))
        } catch {
            FileHandle.standardError.write(Data(
                "SpikeHarness failed: \(error)\n".utf8
            ))
            exit(1)
        }
    }
}

// MARK: - Reference string loading.

private func readReferenceStrings(at url: URL) throws -> [String] {
    let data = try String(contentsOf: url, encoding: .utf8)
    let lines = data
        .split(whereSeparator: \.isNewline)
        .map { String($0) }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    return lines
}

// MARK: - Tokenization + padding to fixed length 256.

private func tokenizeAndPad(
    text: String,
    tokenizer: Tokenizer
) throws -> (tokenIDs: [Int32], attentionMask: [Int32]) {
    // swift-transformers' Tokenizer.encode(text:) returns the full BERT
    // WordPiece ID sequence INCLUDING special tokens ([CLS]/[SEP]). recall's
    // Python tokenizer.enable_truncation(max_length=256) + enable_padding
    // path produces the same shape, so we truncate-then-pad here to match.
    let rawIDs = tokenizer.encode(text: text)
    var truncated = rawIDs
    if truncated.count > maxSequenceLength {
        truncated = Array(truncated.prefix(maxSequenceLength))
    }
    let realLength = truncated.count

    var tokenIDs = [Int32](repeating: padTokenId, count: maxSequenceLength)
    var attentionMask = [Int32](repeating: 0, count: maxSequenceLength)
    for i in 0..<realLength {
        tokenIDs[i] = Int32(truncated[i])
        attentionMask[i] = 1
    }
    return (tokenIDs, attentionMask)
}

// MARK: - CoreML inference.

private enum SpikeHarnessError: Error, CustomStringConvertible {
    case missingFeature(String)
    case unexpectedShape(String)

    var description: String {
        switch self {
        case .missingFeature(let name):
            return "CoreML output missing expected feature: \(name)"
        case .unexpectedShape(let detail):
            return "CoreML output had unexpected shape: \(detail)"
        }
    }
}

private func runCoreML(
    model: MLModel,
    tokenIDs: [Int32],
    attentionMask: [Int32]
) throws -> [Float] {
    let inputIDsArray = try MLMultiArray(shape: [1, NSNumber(value: maxSequenceLength)], dataType: .int32)
    let attentionMaskArray = try MLMultiArray(shape: [1, NSNumber(value: maxSequenceLength)], dataType: .int32)

    // Fill the MLMultiArrays. Use the typed buffer pointer for speed; both
    // arrays are dense and contiguous so a straight memcpy is safe.
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
        throw SpikeHarnessError.missingFeature(tokenEmbeddingsFeatureName)
    }
    guard let multi = tokenEmbeddingsValue.multiArrayValue else {
        throw SpikeHarnessError.missingFeature("\(tokenEmbeddingsFeatureName) (not a multiArray)")
    }

    let expectedCount = maxSequenceLength * embeddingDimension
    guard multi.count == expectedCount else {
        throw SpikeHarnessError.unexpectedShape(
            "expected \(expectedCount) elements ([1, \(maxSequenceLength), "
            + "\(embeddingDimension)]); got \(multi.count) with shape "
            + "\(multi.shape.map { $0.intValue })"
        )
    }

    // Convert to [Float] regardless of underlying dtype (mlprogram defaults
    // to FP16 storage; we materialize FP32 for the Accelerate math below).
    var floats = [Float](repeating: 0, count: expectedCount)
    switch multi.dataType {
    case .float32:
        let src = multi.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<expectedCount { floats[i] = src[i] }
    case .float16:
        // CoreML 14+ MLMultiArray surfaces FP16 via `Float16`. Convert in a loop;
        // the cost is negligible at 256 * 384 = 98k elements.
        let src = multi.dataPointer.assumingMemoryBound(to: Float16.self)
        for i in 0..<expectedCount { floats[i] = Float(src[i]) }
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
private func meanPool(
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
                vDSP_vadd(rowPtr, 1, dstBuf.baseAddress!, 1, dstBuf.baseAddress!, 1, vDSP_Length(embeddingDimension))
            }
        }
    }
    let denom = max(maskSum, 1e-9)
    var result = [Float](repeating: 0, count: embeddingDimension)
    var inv = 1.0 / denom
    sum.withUnsafeBufferPointer { srcBuf in
        result.withUnsafeMutableBufferPointer { dstBuf in
            vDSP_vsmul(srcBuf.baseAddress!, 1, &inv, dstBuf.baseAddress!, 1, vDSP_Length(embeddingDimension))
        }
    }
    return result
}

// MARK: - L2 normalization.

/// Normalize a 384-vector to unit L2 norm. Matches the `np.linalg.norm` +
/// `clip(min=1e-9)` divide that recall/embedding.py does.
private func l2Normalize(_ vec: [Float]) -> [Float] {
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
            vDSP_vsmul(srcBuf.baseAddress!, 1, &inv, dstBuf.baseAddress!, 1, vDSP_Length(vec.count))
        }
    }
    return result
}

// MARK: - JSON output.

private func writeJSON(records: [OutputRecord], to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(records)
    try data.write(to: url, options: .atomic)
}
