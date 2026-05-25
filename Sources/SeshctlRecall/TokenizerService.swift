// TokenizerService — wraps huggingface/swift-transformers' AutoTokenizer for
// the all-MiniLM-L6-v2 WordPiece tokenizer and produces fixed-shape
// (batch × 256) Int32 input_ids / attention_mask tensors suitable for the
// CoreML embedding model used by EmbeddingService.
//
// The tokenization shape (truncate-then-right-pad to 256, attention mask 1
// for real tokens / 0 for pad) matches the Python recall pipeline exactly —
// see `.agents/spikes/2026-05-25-recall-spike/` for the parity-spike proof.

import Foundation
import Tokenizers

/// A batch of tokenized texts, padded to a fixed sequence length.
///
/// All three arrays have the same outer count (= input texts count). Each
/// `inputIDs[i]` and `attentionMask[i]` is exactly `maxSequenceLength` long.
/// `realLengths[i]` is the number of non-pad tokens (i.e. the number of `1`s
/// in `attentionMask[i]`); useful for callers who want to know the
/// pre-padding length without rescanning the mask.
public struct TokenizedBatch: Sendable {
    public let inputIDs: [[Int32]]
    public let attentionMask: [[Int32]]
    public let realLengths: [Int]

    public init(inputIDs: [[Int32]], attentionMask: [[Int32]], realLengths: [Int]) {
        self.inputIDs = inputIDs
        self.attentionMask = attentionMask
        self.realLengths = realLengths
    }

    /// Empty batch sentinel — used when callers pass `encode([])`.
    public static let empty = TokenizedBatch(inputIDs: [], attentionMask: [], realLengths: [])
}

/// An actor that owns a single `Tokenizer` instance and produces fixed-shape
/// `TokenizedBatch` values for batches of input strings.
///
/// Construction is `async` because swift-transformers' `AutoTokenizer.from`
/// is async (it reads + parses `tokenizer.json` and `tokenizer_config.json`).
public actor TokenizerService {
    // MARK: - Constants (mirror the Python recall pipeline + the Phase 1 spike).

    private static let maxSequenceLength: Int = 256
    private static let padTokenID: Int32 = 0

    // MARK: - Stored state.

    private let tokenizer: Tokenizer

    // MARK: - Initialization.

    /// Load the WordPiece tokenizer from a folder containing both
    /// `tokenizer.json` and `tokenizer_config.json` (the two files
    /// swift-transformers' `AutoTokenizer.from(modelFolder:)` requires).
    public init(tokenizerFolderURL: URL) async throws {
        self.tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerFolderURL)
    }

    // MARK: - Public API.

    /// Encode a batch of texts into fixed-shape token IDs + attention masks.
    ///
    /// For each text:
    /// - Run the tokenizer (which emits `[CLS] tokens... [SEP]` for BERT).
    /// - Truncate to `maxSequenceLength` if the raw token sequence is longer.
    /// - Right-pad with `padTokenID` (= 0) to exactly `maxSequenceLength`.
    /// - Produce a matching attention mask: 1 for real tokens, 0 for pad.
    ///
    /// Edge cases:
    /// - Empty `texts` → returns `TokenizedBatch.empty` (no tokenizer calls).
    /// - Empty string → tokenizer typically produces `[CLS][SEP]` = 2 tokens;
    ///   we accept that as-is and pad the remaining 254 slots.
    /// - Input that tokenizes to > 256 tokens → truncated to 256, attention
    ///   mask is all 1s.
    public func encode(_ texts: [String]) -> TokenizedBatch {
        guard !texts.isEmpty else { return .empty }

        var inputIDs: [[Int32]] = []
        var attentionMasks: [[Int32]] = []
        var realLengths: [Int] = []
        inputIDs.reserveCapacity(texts.count)
        attentionMasks.reserveCapacity(texts.count)
        realLengths.reserveCapacity(texts.count)

        for text in texts {
            // swift-transformers' Tokenizer.encode(text:) returns the full
            // BERT WordPiece ID sequence INCLUDING special tokens. The
            // Python recall path with enable_truncation(max_length=256) +
            // enable_padding produces the same shape, so we truncate-then-
            // pad here to match (proven byte-identical by the Phase 1 spike).
            let rawIDs = tokenizer.encode(text: text)
            var truncated = rawIDs
            if truncated.count > Self.maxSequenceLength {
                truncated = Array(truncated.prefix(Self.maxSequenceLength))
            }
            let realLength = truncated.count

            var ids = [Int32](repeating: Self.padTokenID, count: Self.maxSequenceLength)
            var mask = [Int32](repeating: 0, count: Self.maxSequenceLength)
            for i in 0..<realLength {
                ids[i] = Int32(truncated[i])
                mask[i] = 1
            }
            inputIDs.append(ids)
            attentionMasks.append(mask)
            realLengths.append(realLength)
        }

        return TokenizedBatch(
            inputIDs: inputIDs,
            attentionMask: attentionMasks,
            realLengths: realLengths
        )
    }
}
