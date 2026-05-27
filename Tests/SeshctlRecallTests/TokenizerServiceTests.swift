// TokenizerServiceTests — cover the WordPiece tokenizer wrapper that feeds
// EmbeddingService. Resolves the tokenizer folder via the production
// resolver (`EmbeddingService.bundledTokenizerFolderURL()`) so these tests
// find the bundled `Sources/SeshctlRecall/Models/` resources regardless of
// whether the test bundle has its own `Models/` directory.

import Foundation
import Testing

@testable import SeshctlRecall

// MARK: - Test helpers.

/// Locate the tokenizer folder bundled with the SeshctlRecall target.
/// Returns `nil` only if neither the .app resources nor the SwiftPM
/// `Bundle.module/Models/` location resolves — a Phase 7 regression.
private func bundledTokenizerFolder() -> URL? {
    EmbeddingService.bundledTokenizerFolderURL()
}

// MARK: - Tests.

@Suite("TokenizerService")
struct TokenizerServiceTests {
    @Test("Init with bundled tokenizer succeeds")
    func initWithBundledTokenizerSucceeds() async throws {
        guard let folder = bundledTokenizerFolder() else {
            Issue.record("Bundle.module could not resolve Models/tokenizer.json — Phase 7 regression")
            return
        }
        _ = try await TokenizerService(tokenizerFolderURL: folder)
    }

    @Test("Encode produces correct fixed shapes (batch × 256)")
    func encodeShapesAreCorrect() async throws {
        guard let folder = bundledTokenizerFolder() else {
            Issue.record("Bundle.module could not resolve Models/tokenizer.json — Phase 7 regression")
            return
        }
        let service = try await TokenizerService(tokenizerFolderURL: folder)
        let batch = await service.encode(["hello", "world"])
        #expect(batch.inputIDs.count == 2)
        #expect(batch.attentionMask.count == 2)
        #expect(batch.realLengths.count == 2)
        for row in batch.inputIDs { #expect(row.count == 256) }
        for row in batch.attentionMask { #expect(row.count == 256) }
    }

    @Test("Padding zeroes out attention mask + input IDs past real length")
    func paddingZeroesOutAttentionMask() async throws {
        guard let folder = bundledTokenizerFolder() else {
            Issue.record("Bundle.module could not resolve Models/tokenizer.json — Phase 7 regression")
            return
        }
        let service = try await TokenizerService(tokenizerFolderURL: folder)
        let batch = await service.encode(["hi"])
        #expect(batch.realLengths.count == 1)
        let realLen = batch.realLengths[0]
        #expect(realLen > 0 && realLen < 256)
        for i in realLen..<256 {
            #expect(batch.attentionMask[0][i] == 0, "mask[\(i)] should be 0 (pad), got \(batch.attentionMask[0][i])")
            #expect(batch.inputIDs[0][i] == 0, "inputIDs[\(i)] should be 0 (pad token), got \(batch.inputIDs[0][i])")
        }
        // Real tokens (positions 0..<realLen) should all have mask 1.
        for i in 0..<realLen {
            #expect(batch.attentionMask[0][i] == 1, "mask[\(i)] should be 1 (real), got \(batch.attentionMask[0][i])")
        }
    }

    @Test("Truncation: a 5000-char input is truncated to exactly 256 tokens")
    func truncationDoesNotPanic() async throws {
        guard let folder = bundledTokenizerFolder() else {
            Issue.record("Bundle.module could not resolve Models/tokenizer.json — Phase 7 regression")
            return
        }
        let service = try await TokenizerService(tokenizerFolderURL: folder)
        let longString = String(repeating: "a ", count: 2500) // 5000 chars
        let batch = await service.encode([longString])
        #expect(batch.realLengths.count == 1)
        #expect(batch.realLengths[0] == 256, "expected truncated to 256, got \(batch.realLengths[0])")
        // Attention mask should be all 1s.
        for i in 0..<256 {
            #expect(batch.attentionMask[0][i] == 1, "mask[\(i)] should be 1 when truncated to full length")
        }
    }

    @Test("Empty text array returns empty TokenizedBatch")
    func emptyTextArray() async throws {
        guard let folder = bundledTokenizerFolder() else {
            Issue.record("Bundle.module could not resolve Models/tokenizer.json — Phase 7 regression")
            return
        }
        let service = try await TokenizerService(tokenizerFolderURL: folder)
        let batch = await service.encode([])
        #expect(batch.inputIDs.isEmpty)
        #expect(batch.attentionMask.isEmpty)
        #expect(batch.realLengths.isEmpty)
    }

    @Test("Empty string encodes to just the [CLS][SEP] special tokens")
    func encodeEmptyStringProducesSpecialTokensOnly() async throws {
        guard let folder = bundledTokenizerFolder() else {
            Issue.record("Bundle.module could not resolve Models/tokenizer.json — Phase 7 regression")
            return
        }
        let tokenizer = try await TokenizerService(tokenizerFolderURL: folder)
        let batch = await tokenizer.encode([""])
        #expect(batch.realLengths == [2], "[CLS][SEP] = 2 tokens")
        // First two positions should be CLS (101) and SEP (102) for BERT WordPiece
        #expect(batch.inputIDs[0][0] == 101)
        #expect(batch.inputIDs[0][1] == 102)
        // attentionMask reflects only the 2 real tokens
        #expect(batch.attentionMask[0][0] == 1)
        #expect(batch.attentionMask[0][1] == 1)
        #expect(batch.attentionMask[0][2] == 0)
    }
}
