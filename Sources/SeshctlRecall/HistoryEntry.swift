// HistoryEntry — value type backing one row in `recall_entries`.
//
// Adapters produce `HistoryEntry` values from per-tool transcripts; the
// `Indexer` embeds each entry's `text` and writes both to the SQLite store
// in a single transaction per batch. `textHash` is the SHA-256 hex of the
// UTF-8 text bytes and is part of the dedup key — the DB enforces
// `UNIQUE (text_hash, agent, session_id)`, so same content from the same
// session re-walked is collapsed, but identical content from different
// sessions is preserved (e.g. multiple `ok`s across multiple chats all get
// indexed).

import CryptoKit
import Foundation

public struct HistoryEntry: Sendable, Equatable {
    /// Row id assigned by SQLite. `nil` before insert; populated by
    /// `VectorStore.insert` for the rows that landed (skipped duplicates do
    /// not show up in the returned id list).
    public let id: Int64?
    /// Stable tool/adapter tag — one of `"claude"`, `"codex"`, `"gemini"`.
    /// Matches the Python recall pipeline's `agent` field so downstream
    /// consumers (and the UI's resume routing) don't drift.
    public let agent: String
    /// `"user"` or `"assistant"`.
    public let role: String
    /// Per-tool conversation id (the same id a `RecallResult` carries).
    public let sessionID: String
    /// Absolute project path (or empty string when the adapter can't recover
    /// one — e.g. a transcript that predates per-conversation project tags).
    public let project: String
    /// Unix seconds. Used for the `recall_entries_timestamp` index +
    /// `RecallResult.timestamp`.
    public let timestamp: Double
    /// Raw message text (post-cleanup). Embedded as-is.
    public let text: String
    /// SHA-256 hex digest of `text` (UTF-8 bytes), lowercase. Part of the
    /// composite dedup key — the DB enforces
    /// `UNIQUE (text_hash, agent, session_id)`, so same content from the
    /// same session re-walked is collapsed, but identical content from
    /// different sessions is preserved (multiple `ok`s across multiple
    /// chats all get indexed). Adapters set this via
    /// `HistoryEntry.textHash(for:)` before handing the entry to the store.
    public let textHash: String

    public init(
        id: Int64? = nil,
        agent: String,
        role: String,
        sessionID: String,
        project: String,
        timestamp: Double,
        text: String,
        textHash: String
    ) {
        self.id = id
        self.agent = agent
        self.role = role
        self.sessionID = sessionID
        self.project = project
        self.timestamp = timestamp
        self.text = text
        self.textHash = textHash
    }

    /// SHA-256 of the UTF-8 bytes of `text`, lowercase hex. Deterministic.
    /// Adapters call this to populate `textHash` before insert.
    public static func textHash(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
