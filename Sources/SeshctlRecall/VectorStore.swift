// VectorStore — GRDB-backed persistence for `recall_entries`,
// `recall_embeddings`, and `recall_cursors`.
//
// Concurrency: `actor` so write transactions can't race with each other or
// with sibling reads issued from the same actor. The underlying GRDB
// `DatabasePool` is itself thread-safe; the actor adds an extra layer of
// serialization for the multi-step routines (`insert` is "skip if hash
// exists, else insert + embed") that would otherwise need explicit
// transaction nesting.
//
// Schema: see migrations `v13_create_recall_tables` and
// `v16_create_recall_fts` in `Sources/SeshctlCore/Database.swift`.
//
// Text and embeddings land separately. `insertText` makes a message
// keyword-searchable immediately (the FTS triggers index it on insert);
// `insertEmbeddings` fills in its vector later, when semantic search runs.
// An entry without an embedding is normal, not corruption.
//
// Embedding serialization: raw little-endian FP32 byte buffer (no version
// tag). 384 floats × 4 bytes = 1536 bytes per row. Endianness matches the
// CPU we encoded on (Apple Silicon + Intel are both little-endian) — we
// never serve the DB cross-platform so this is fine. If we ever bump dtype,
// add a new column (e.g. `vector_v2`) via a new migration rather than
// re-decoding old blobs.

import Foundation
import GRDB
import SeshctlCore

public actor VectorStore {
    private let database: SeshctlDatabase

    public init(database: SeshctlDatabase) {
        self.database = database
    }

    // MARK: - Inserts.

    /// Insert a batch of (entry, embedding) pairs in a single write
    /// transaction. Entries whose `(text_hash, agent, session_id)` triple
    /// already exists in `recall_entries` are silently skipped (the
    /// composite UNIQUE constraint is the dedup key — adapters re-walk
    /// transcripts on every refresh; identical content from different
    /// sessions is preserved).
    ///
    /// - Returns: the row ids of the entries that were actually inserted,
    ///   in the same order as the input. Skipped duplicates produce no id
    ///   in the returned array.
    ///
    /// Precondition: `entries.count == embeddings.count`. Each embedding
    /// must be a 384-float vector (the model's output dimension); shorter
    /// or longer vectors are accepted and round-tripped as-is, but search
    /// will misbehave.
    @discardableResult
    public func insert(entries: [HistoryEntry], embeddings: [[Float]]) throws -> [Int64] {
        precondition(
            entries.count == embeddings.count,
            "VectorStore.insert: entries.count (\(entries.count)) != embeddings.count (\(embeddings.count))"
        )
        guard !entries.isEmpty else { return [] }

        return try database.dbPool.write { db in
            var inserted: [Int64] = []
            inserted.reserveCapacity(entries.count)
            for (entry, vector) in zip(entries, embeddings) {
                // INSERT OR IGNORE — UNIQUE(text_hash, agent, session_id) drops duplicates.
                try db.execute(sql: """
                    INSERT OR IGNORE INTO recall_entries
                        (agent, role, session_id, project, timestamp, text, text_hash)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    entry.agent,
                    entry.role,
                    entry.sessionID,
                    entry.project,
                    entry.timestamp,
                    entry.storedText,
                    entry.textHash,
                ])
                // `changes` is 1 if the row landed, 0 if IGNOREd.
                guard db.changesCount == 1 else { continue }
                let rowID = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO recall_embeddings (entry_id, vector)
                    VALUES (?, ?)
                """, arguments: [
                    rowID,
                    Self.encode(vector: vector),
                ])
                inserted.append(rowID)
            }
            return inserted
        }
    }

    /// Rows per write transaction in `insertText`.
    static let insertTextBatchSize = 500

    /// Insert entries without embeddings. Same dedup rule as
    /// `insert(entries:embeddings:)`. The FTS triggers index each landed
    /// row, so it's keyword-searchable as soon as this returns.
    ///
    /// Writes in transactions of `insertTextBatchSize` rows. A first run
    /// inserts the whole history (16k+ rows, each with FTS work), and the
    /// database has no busy timeout, so one long transaction would make the
    /// hooks' session-status writes fail for its whole duration.
    ///
    /// - Returns: the row ids of the entries that were actually inserted.
    @discardableResult
    public func insertText(entries: [HistoryEntry]) throws -> [Int64] {
        var inserted: [Int64] = []
        inserted.reserveCapacity(entries.count)
        var start = entries.startIndex
        while start < entries.endIndex {
            let end = min(start + Self.insertTextBatchSize, entries.endIndex)
            inserted += try insertTextBatch(entries[start..<end])
            start = end
        }
        return inserted
    }

    private func insertTextBatch(_ entries: ArraySlice<HistoryEntry>) throws -> [Int64] {
        try database.dbPool.write { db in
            var inserted: [Int64] = []
            inserted.reserveCapacity(entries.count)
            for entry in entries {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO recall_entries
                        (agent, role, session_id, project, timestamp, text, text_hash)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    entry.agent,
                    entry.role,
                    entry.sessionID,
                    entry.project,
                    entry.timestamp,
                    entry.storedText,
                    entry.textHash,
                ])
                guard db.changesCount == 1 else { continue }
                inserted.append(db.lastInsertedRowID)
            }
            return inserted
        }
    }

    /// Store embeddings for entries already in `recall_entries`. Replaces
    /// any existing vector for the same id.
    public func insertEmbeddings(ids: [Int64], vectors: [[Float]]) throws {
        precondition(
            ids.count == vectors.count,
            "VectorStore.insertEmbeddings: ids.count (\(ids.count)) != vectors.count (\(vectors.count))"
        )
        guard !ids.isEmpty else { return }
        try database.dbPool.write { db in
            for (id, vector) in zip(ids, vectors) {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO recall_embeddings (entry_id, vector)
                    VALUES (?, ?)
                """, arguments: [id, Self.encode(vector: vector)])
            }
        }
    }

    // MARK: - Reads.

    /// Load every (entry_id, vector) pair into memory. Used by Search for
    /// brute-force top-K cosine similarity. At 8k entries × 1.5KB per
    /// embedding this is ~12MB — trivial.
    ///
    /// - Returns: parallel arrays. `ids[i]` is the row id whose embedding
    ///   is `vectors[i]`. Ordered by `entry_id` ASC.
    public func loadAllEmbeddings() throws -> (ids: [Int64], vectors: [[Float]]) {
        try database.dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT entry_id, vector FROM recall_embeddings ORDER BY entry_id ASC"
            )
            var ids: [Int64] = []
            var vectors: [[Float]] = []
            ids.reserveCapacity(rows.count)
            vectors.reserveCapacity(rows.count)
            for row in rows {
                let id: Int64 = row["entry_id"]
                let data: Data = row["vector"]
                ids.append(id)
                vectors.append(Self.decode(data: data))
            }
            return (ids, vectors)
        }
    }

    /// Hydrate `HistoryEntry`s for a set of row ids, preserving the order
    /// of `ids`. Unknown ids are silently dropped from the result.
    public func entries(forIDs ids: [Int64]) throws -> [HistoryEntry] {
        guard !ids.isEmpty else { return [] }
        return try database.dbPool.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, agent, role, session_id, project, timestamp, text, text_hash
                    FROM recall_entries
                    WHERE id IN (\(placeholders))
                """,
                arguments: StatementArguments(ids)
            )
            // Map by id, then reproject in the caller's order.
            var byID: [Int64: HistoryEntry] = [:]
            byID.reserveCapacity(rows.count)
            for row in rows {
                let entry = Self.entry(from: row)
                if let entryID = entry.id {
                    byID[entryID] = entry
                }
            }
            return ids.compactMap { byID[$0] }
        }
    }

    /// Every stored message of one session, oldest first. The index keeps
    /// one copy of each distinct message text per session, so a repeated
    /// message ("yes") appears once, at its first occurrence.
    public func entries(agent: String, sessionID: String) throws -> [HistoryEntry] {
        try database.dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, agent, role, session_id, project, timestamp, text, text_hash
                    FROM recall_entries
                    WHERE agent = ? AND session_id = ?
                    ORDER BY timestamp ASC, id ASC
                """,
                arguments: [agent, sessionID]
            )
            return rows.map(Self.entry(from:))
        }
    }

    /// Up to `limit` entries that have no embedding yet, oldest id first.
    public func entriesMissingEmbeddings(limit: Int) throws -> [HistoryEntry] {
        try database.dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT e.id, e.agent, e.role, e.session_id, e.project, e.timestamp, e.text, e.text_hash
                    FROM recall_entries e
                    WHERE NOT EXISTS (SELECT 1 FROM recall_embeddings m WHERE m.entry_id = e.id)
                    ORDER BY e.id ASC
                    LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.map(Self.entry(from:))
        }
    }

    /// Number of entries that have an embedding.
    public func embeddingCount() throws -> Int {
        try database.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recall_embeddings") ?? 0
        }
    }

    /// Step 1 of keyword search: messages matching an FTS5 MATCH
    /// expression, best first, without their text.
    ///
    /// - Parameters:
    ///   - match: an FTS5 query, normally from
    ///     `KeywordQuery.matchExpression(for:)`. Raw user input can be a
    ///     syntax error.
    ///   - limit: cap on message-level matches. Callers group these by session.
    /// - Returns: matches ordered by FTS5's `bm25` (more negative is better).
    public func keywordCandidates(match: String, limit: Int) throws -> [KeywordCandidate] {
        try database.dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT e.id, e.agent, e.session_id, e.timestamp, bm25(recall_fts) AS rank
                    FROM recall_fts
                    JOIN recall_entries e ON e.id = recall_fts.rowid
                    WHERE recall_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                """,
                arguments: [match, limit]
            )
            return rows.map { row in
                KeywordCandidate(
                    id: row["id"],
                    agent: row["agent"],
                    sessionID: row["session_id"],
                    timestamp: row["timestamp"],
                    rank: row["rank"]
                )
            }
        }
    }

    /// Step 2 of keyword search: full entries and snippets for the chosen
    /// candidates. `snippet()` costs time in proportion to a message's
    /// length, which is why it runs only for the rows that get shown.
    ///
    /// - Parameters:
    ///   - match: the same MATCH expression the candidates came from.
    ///     `snippet()` needs it to find the matched terms.
    ///   - ids: candidate ids, in display order.
    /// - Returns: hits in the order of `ids`. Ids that no longer match are
    ///   dropped. Each snippet wraps matched terms in `KeywordHit.matchStart` /
    ///   `KeywordHit.matchEnd`.
    public func keywordHits(match: String, ids: [Int64]) throws -> [KeywordHit] {
        guard !ids.isEmpty else { return [] }
        return try database.dbPool.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            var arguments: StatementArguments = [KeywordHit.matchStart, KeywordHit.matchEnd, match]
            arguments += StatementArguments(ids)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT e.id, e.agent, e.role, e.session_id, e.project, e.timestamp, e.text, e.text_hash,
                           snippet(recall_fts, 0, ?, ?, '…', 16) AS snippet
                    FROM recall_fts
                    JOIN recall_entries e ON e.id = recall_fts.rowid
                    WHERE recall_fts MATCH ? AND recall_fts.rowid IN (\(placeholders))
                """,
                arguments: arguments
            )
            var byID: [Int64: KeywordHit] = [:]
            for row in rows {
                let entry = Self.entry(from: row)
                if let id = entry.id {
                    byID[id] = KeywordHit(entry: entry, snippet: row["snippet"])
                }
            }
            return ids.compactMap { byID[$0] }
        }
    }

    private static func entry(from row: Row) -> HistoryEntry {
        HistoryEntry(
            id: row["id"],
            agent: row["agent"],
            role: row["role"],
            sessionID: row["session_id"],
            project: row["project"],
            timestamp: row["timestamp"],
            text: row["text"],
            textHash: row["text_hash"]
        )
    }

    /// Total number of rows in `recall_entries`. Used for indexing UX
    /// ("indexing N entries") and tests.
    public func entryCount() throws -> Int {
        try database.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recall_entries") ?? 0
        }
    }

    // MARK: - Cursors.

    /// Read the opaque cursor body for an adapter, or `nil` if it has never
    /// run before.
    public func readCursor(adapterName: String) throws -> Data? {
        try database.dbPool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT cursor_json FROM recall_cursors WHERE adapter_name = ?",
                arguments: [adapterName]
            )
            guard let row else { return nil }
            let json: String = row["cursor_json"]
            return Data(json.utf8)
        }
    }

    /// Persist the opaque cursor body for an adapter. Upsert semantics.
    /// `updated_at` is set to the current unix-seconds time.
    public func writeCursor(adapterName: String, cursor: Data) throws {
        let cursorString = String(data: cursor, encoding: .utf8) ?? ""
        let now = Date().timeIntervalSince1970
        try database.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO recall_cursors (adapter_name, cursor_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(adapter_name) DO UPDATE SET
                    cursor_json = excluded.cursor_json,
                    updated_at = excluded.updated_at
            """, arguments: [adapterName, cursorString, now])
        }
    }

    // MARK: - Reset.

    /// Wipe both `recall_entries` and `recall_embeddings` plus the cursor
    /// table. Cursor wipe ensures the next refresh re-walks from scratch
    /// instead of resuming partway through. (`recall_embeddings` is
    /// cleared by the FK cascade on `recall_entries` deletion, but we
    /// issue the explicit DELETE anyway for clarity.)
    public func clearAllEntriesAndEmbeddings() throws {
        try database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM recall_embeddings")
            try db.execute(sql: "DELETE FROM recall_entries")
            try db.execute(sql: "DELETE FROM recall_cursors")
        }
    }

    // MARK: - BLOB codec.

    /// Encode `[Float]` to a contiguous little-endian FP32 byte buffer.
    /// `Data.init(buffer:)` copies the 4-byte float bytes verbatim; no
    /// padding, no version tag.
    static func encode(vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
    }

    /// Decode a contiguous little-endian FP32 byte buffer back to
    /// `[Float]`. Length is `data.count / 4`.
    static func decode(data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst.bindMemory(to: UInt8.self))
        }
        return floats
    }
}
