// AdapterRegistryTests — smoke test for the production adapter registration
// point. `defaultAdapters()` is the canonical wiring read by the `Indexer`
// at runtime; if a new adapter is added without showing up here, indexing
// silently skips it. The compiler can't catch that (the registry is a value,
// not an exhaustive switch), so this test is the safety net.

import Foundation
import Testing

@testable import SeshctlRecall

@Suite("AdapterRegistry")
struct AdapterRegistryTests {
    @Test("defaultAdapters wires up claude / codex / gemini")
    func defaultAdaptersExposeAllProductionAdapters() {
        let adapters = AdapterRegistry.defaultAdapters()
        let names = adapters.map(\.name)
        #expect(names.contains("claude"))
        #expect(names.contains("codex"))
        #expect(names.contains("gemini"))
        #expect(names.count == adapters.count, "adapter names must be unique")
    }
}
