import Foundation
import SeshctlCore

public struct RecallSearchResponse: Sendable {
    public let results: [RecallResult]
    public let indexingCount: Int?

    public init(results: [RecallResult], indexingCount: Int?) {
        self.results = results
        self.indexingCount = indexingCount
    }
}

public struct RecallService: Sendable {

    public static func search(
        query: String,
        limit: Int = 10,
        onIndexing: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> RecallSearchResponse {
        _ = limit
        _ = onIndexing
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return RecallSearchResponse(results: [], indexingCount: nil) }

        throw RecallError.searchFailed(
            "SeshctlRecall stub — Phase 2 scaffolding; real implementation lands in Phase 6"
        )
    }

    public static func isAvailable() -> Bool {
        // The native SeshctlRecall implementation has no external binary
        // dependency — availability is intrinsic to the bundled module.
        return true
    }
}
