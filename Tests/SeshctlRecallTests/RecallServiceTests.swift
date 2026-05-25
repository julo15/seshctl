import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlRecall

@Suite("RecallService")
struct RecallServiceTests {
    @Test("isAvailable returns true (native implementation, no external binary)")
    func isAvailableReturnsTrue() {
        #expect(RecallService.isAvailable() == true)
    }

    @Test("Search with empty query returns empty results")
    func searchEmptyQuery() async throws {
        let response = try await RecallService.search(query: "")
        #expect(response.results.isEmpty)
        #expect(response.indexingCount == nil)
    }

    @Test("Search with whitespace query returns empty results")
    func searchWhitespaceQuery() async throws {
        let response = try await RecallService.search(query: "   ")
        #expect(response.results.isEmpty)
        #expect(response.indexingCount == nil)
    }

    @Test("Search with a non-empty query throws the Phase 2 stub error")
    func searchNonEmptyQueryThrowsStub() async {
        // Phase 2 scaffolding: real implementation lands in Phase 6.
        await #expect(throws: RecallError.self) {
            _ = try await RecallService.search(query: "hello")
        }
    }
}
