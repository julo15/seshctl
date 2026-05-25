// RecallServiceTests — exercises the static façade. The shared stack holds
// process-wide state (configured database + cached construction Task), so
// each test calls `RecallService._resetForTests()` first to avoid bleed
// between tests + bleed from other test files that may have configured the
// service.
//
// These tests do NOT load the bundled CoreML model — that ships in Phase 7
// and is gated by `EmbeddingServiceTests`. The negative-path test
// `searchWithoutBundledModelThrows` is the proof that the stack is wired all
// the way through; Phase 7 will flip it to a positive assertion.

import Foundation
import Testing

@testable import SeshctlCore
@_spi(Testing) @testable import SeshctlRecall

@Suite("RecallService", .serialized)
struct RecallServiceTests {
    @Test("isAvailable returns true (native implementation, no external binary)")
    func isAvailableReturnsTrue() {
        #expect(RecallService.isAvailable() == true)
    }

    @Test("Empty query short-circuits to empty results without touching the stack")
    func searchEmptyQuery() async throws {
        RecallService._resetForTests()
        let response = try await RecallService.search(query: "")
        #expect(response.results.isEmpty)
        #expect(response.indexingCount == nil)
    }

    @Test("Whitespace-only query short-circuits to empty results")
    func searchWhitespaceQuery() async throws {
        RecallService._resetForTests()
        let response = try await RecallService.search(query: "   \n\t  ")
        #expect(response.results.isEmpty)
        #expect(response.indexingCount == nil)
    }

    @Test("Search before configure() throws a searchFailed error mentioning configure")
    func searchWithoutConfigureThrows() async {
        RecallService._resetForTests()
        await #expect {
            _ = try await RecallService.search(query: "hello world")
        } throws: { error in
            guard let recallError = error as? RecallError,
                  case .searchFailed(let message) = recallError else {
                return false
            }
            return message.contains("configure")
        }
    }

    // Note: there is no full end-to-end search test in this suite. The
    // RecallStack's Indexer would walk the developer's real ~/.claude/projects,
    // ~/.codex, ~/.gemini directories and index thousands of entries — slow,
    // non-deterministic, and not appropriate for a unit-test pass. The Phase 7
    // bundled-model wiring is covered by EmbeddingServiceTests.productionInit
    // LoadsBundledModel; an injectable-adapters test-only API is a possible
    // future addition if we want to assert search() returns empty against a
    // pristine DB.
}
