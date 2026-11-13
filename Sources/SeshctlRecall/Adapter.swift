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

    /// `load`, plus any session titles found in the same pass. `Indexer`
    /// calls this one. The default returns no titles, so only adapters
    /// whose transcripts carry titles implement it.
    func loadWithTitles(cursor: Data?) async throws -> AdapterLoad
}

/// One adapter pass: new entries, session titles seen, and the cursor to
/// persist with them.
public struct AdapterLoad: Sendable {
    public let entries: [HistoryEntry]
    public let titles: [IndexedTitle]
    public let newCursor: Data

    public init(entries: [HistoryEntry], titles: [IndexedTitle] = [], newCursor: Data) {
        self.entries = entries
        self.titles = titles
        self.newCursor = newCursor
    }
}

/// A session title found in a transcript. Either field may be nil; a nil
/// never overwrites a stored value.
public struct IndexedTitle: Sendable, Equatable {
    public let agent: String
    public let sessionID: String
    /// Claude Code's generated title (`{"type":"ai-title"}`).
    public let aiTitle: String?
    /// A user-set name (`{"type":"custom-title"}`), often a remote-control
    /// machine label; `aiTitle` wins when both exist.
    public let customTitle: String?

    public init(agent: String, sessionID: String, aiTitle: String?, customTitle: String?) {
        self.agent = agent
        self.sessionID = sessionID
        self.aiTitle = aiTitle
        self.customTitle = customTitle
    }
}

extension Adapter {
    public func loadWithTitles(cursor: Data?) async throws -> AdapterLoad {
        let (entries, newCursor) = try await load(cursor: cursor)
        return AdapterLoad(entries: entries, newCursor: newCursor)
    }

    /// Convenience sentinel: empty `Data`. Adapters that have no cursor
    /// state to persist may return this from `load`.
    public static var noCursor: Data { Data() }
}
