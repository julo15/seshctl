// Adapter — per-tool transcript walker contract.
//
// One concrete `Adapter` per LLM tool (`ClaudeAdapter`, `CodexAdapter`,
// `GeminiAdapter`) lands in Phase 5. Phase 4 just defines the protocol so
// `Indexer` can be written and tested against a mock.
//
// The cursor body is opaque `Data`. Each adapter picks its own serialization
// (typically a JSON-encoded `[path: mtime]` map mirroring the Python
// recall pipeline's `cursors.json` shape). The store treats it as bytes.

import Foundation

public protocol Adapter: Sendable {
    /// Stable name persisted as `recall_cursors.adapter_name`. Must be
    /// unique across all registered adapters (the table's primary key).
    /// Conventionally lowercase: `"claude"`, `"codex"`, `"gemini"`.
    var name: String { get }

    /// Walk transcripts newer than `cursor` and emit fresh entries.
    ///
    /// - Parameter cursor: the previously persisted cursor body, or `nil`
    ///   on the first run for this adapter. `Data()` (empty) is also a
    ///   valid "no prior state" signal — adapters should treat empty +
    ///   `nil` identically.
    /// - Returns: the new entries (in any order — `Indexer` doesn't reorder
    ///   them) and the cursor body to persist atomically with them.
    ///
    /// Adapters are responsible for setting `HistoryEntry.textHash` via
    /// `HistoryEntry.textHash(for:)` before returning. The store's UNIQUE
    /// constraint silently drops duplicates, but pre-hashing keeps the
    /// caller honest.
    func load(cursor: Data?) async throws -> (entries: [HistoryEntry], newCursor: Data)
}

extension Adapter {
    /// Convenience sentinel: empty `Data`. Adapters that have no cursor
    /// state to persist may return this from `load`.
    public static var noCursor: Data { Data() }
}
