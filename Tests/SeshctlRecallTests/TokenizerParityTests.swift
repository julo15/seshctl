// TokenizerParityTests — assert byte-for-byte token-ID parity between
// `TokenizerService` and the Python `tokenizers` library that the original
// recall implementation used.
//
// Fixture: `Fixtures/tokenizer-parity.json` is captured by running
// `.agents/spikes/2026-05-25-recall-spike/`-style tokenization against the
// SAME `tokenizer.json` that ships under
// `Sources/SeshctlRecall/Models/tokenizer.json`. If the model is ever bumped,
// re-capture the fixture (HF `tokenizers` against the new tokenizer.json) and
// commit the updated JSON — there is no run-time Python dependency.
//
// Schema:
//   { "max_length": 256, "records": [
//       { "input": "...", "token_ids": [Int; 256],
//         "attention_mask": [Int; 256], "real_length": Int }, ...
//   ]}

import Foundation
import Testing

@testable import SeshctlRecall

private struct ParityFixture: Decodable {
    let maxLength: Int
    let records: [Record]

    struct Record: Decodable {
        let input: String
        let tokenIDs: [Int32]
        let attentionMask: [Int32]
        let realLength: Int

        enum CodingKeys: String, CodingKey {
            case input
            case tokenIDs = "token_ids"
            case attentionMask = "attention_mask"
            case realLength = "real_length"
        }
    }

    enum CodingKeys: String, CodingKey {
        case maxLength = "max_length"
        case records
    }
}

private func loadFixture() throws -> ParityFixture {
    guard let url = Bundle.module.url(
        forResource: "tokenizer-parity",
        withExtension: "json",
        subdirectory: "Fixtures"
    ) else {
        throw NSError(
            domain: "TokenizerParityTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Fixtures/tokenizer-parity.json not in test bundle"]
        )
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(ParityFixture.self, from: data)
}

private func bundledTokenizerFolder() -> URL? {
    EmbeddingService.bundledTokenizerFolderURL()
}

@Suite("TokenizerService parity vs Python")
struct TokenizerParityTests {
    @Test("Token IDs match Python HF tokenizers for all 20 reference strings")
    func tokenIDsAreByteIdentical() async throws {
        let fixture = try loadFixture()
        #expect(fixture.maxLength == 256)
        #expect(fixture.records.count == 20, "fixture should hold 20 reference strings")

        guard let folder = bundledTokenizerFolder() else {
            Issue.record("Bundle.module could not resolve Models/tokenizer.json — Phase 7 regression")
            return
        }
        let service = try await TokenizerService(tokenizerFolderURL: folder)

        let inputs = fixture.records.map(\.input)
        let batch = await service.encode(inputs)
        #expect(batch.inputIDs.count == fixture.records.count)

        for (i, expected) in fixture.records.enumerated() {
            let actualIDs = batch.inputIDs[i]
            let actualMask = batch.attentionMask[i]
            let actualLen = batch.realLengths[i]

            #expect(
                actualLen == expected.realLength,
                "real_length mismatch for record \(i) (\(expected.input)): swift=\(actualLen) python=\(expected.realLength)"
            )
            #expect(
                actualIDs == expected.tokenIDs,
                "token_ids diverged for record \(i) (\(expected.input))"
            )
            #expect(
                actualMask == expected.attentionMask,
                "attention_mask diverged for record \(i) (\(expected.input))"
            )
        }
    }
}
