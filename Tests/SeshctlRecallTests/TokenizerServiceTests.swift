// TokenizerServiceTests — cover the WordPiece tokenizer wrapper that feeds
// EmbeddingService. All tests depend on the Phase 1 spike's local
// `tokenizer.json` + `tokenizer_config.json` artifacts; tests skip
// gracefully when they're absent.

import Foundation
import Testing

@testable import SeshctlRecall

// MARK: - Test helpers.

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

/// Returns the spike's tokenizer folder URL iff both required files exist.
private func spikeTokenizerFolderIfAvailable() -> URL? {
    let folder = repoRoot().appendingPathComponent(".agents/spikes/2026-05-25-recall-spike")
    let fm = FileManager.default
    guard fm.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path),
          fm.fileExists(atPath: folder.appendingPathComponent("tokenizer_config.json").path)
    else { return nil }
    return folder
}

// MARK: - Tests.

@Suite("TokenizerService")
struct TokenizerServiceTests {
    @Test("Init with spike tokenizer succeeds")
    func initWithSpikeTokenizerSucceeds() async throws {
        guard let folder = spikeTokenizerFolderIfAvailable() else { return }
        _ = try await TokenizerService(tokenizerFolderURL: folder)
    }

    @Test("Encode produces correct fixed shapes (batch × 256)")
    func encodeShapesAreCorrect() async throws {
        guard let folder = spikeTokenizerFolderIfAvailable() else { return }
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
        guard let folder = spikeTokenizerFolderIfAvailable() else { return }
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
        guard let folder = spikeTokenizerFolderIfAvailable() else { return }
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
        guard let folder = spikeTokenizerFolderIfAvailable() else { return }
        let service = try await TokenizerService(tokenizerFolderURL: folder)
        let batch = await service.encode([])
        #expect(batch.inputIDs.isEmpty)
        #expect(batch.attentionMask.isEmpty)
        #expect(batch.realLengths.isEmpty)
    }
}
