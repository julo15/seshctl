// AdapterRegistry — the canonical list of production adapters wired into
// the `Indexer` at runtime. Tests construct their own MockAdapter sets and
// don't go through this; production code calls `defaultAdapters()`.

import Foundation

public enum AdapterRegistry {
    public static func defaultAdapters() -> [any Adapter] {
        [ClaudeAdapter(), CodexAdapter(), GeminiAdapter()]
    }
}
