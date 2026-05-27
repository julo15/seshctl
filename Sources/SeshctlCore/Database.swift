import Foundation
import GRDB

public struct SeshctlDatabase: Sendable {
    /// Exposed publicly so sibling modules (notably `SeshctlRecall`) can run
    /// transactions against the same on-disk store without going through
    /// `SeshctlDatabase`'s session-centric helpers. Keeping a single
    /// `DatabasePool` per process is load-bearing for WAL concurrency.
    public let dbPool: DatabasePool

    /// Opens (or creates) the database at the given path with WAL mode.
    public init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var config = Configuration()
        config.prepareDatabase { db in
            // WAL mode for concurrent read/write safety
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        dbPool = try DatabasePool(path: path, configuration: config)
        try migrate()
    }

    /// Creates a temporary file-backed database for testing.
    public static func temporary() throws -> SeshctlDatabase {
        let path = NSTemporaryDirectory() + "seshctl-test-\(UUID().uuidString).db"
        return try SeshctlDatabase(path: path)
    }

    private init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_sessions") { db in
            try db.create(table: "sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("conversation_id", .text)
                t.column("tool", .text).notNull()
                t.column("directory", .text).notNull()
                t.column("last_ask", .text)
                t.column("status", .text).notNull().defaults(to: "idle")
                t.column("pid", .integer)
                t.column("window_id", .text)
                t.column("started_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(
                index: "idx_sessions_updated_at", on: "sessions",
                columns: ["updated_at"])
            try db.create(
                index: "idx_sessions_status", on: "sessions",
                columns: ["status"])
            try db.create(
                index: "idx_sessions_conversation", on: "sessions",
                columns: ["conversation_id"])
            try db.create(
                index: "idx_sessions_pid_tool", on: "sessions",
                columns: ["pid", "tool"])
        }

        migrator.registerMigration("v2_add_host_app") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "host_app_bundle_id", .text)
                t.add(column: "host_app_name", .text)
            }
        }

        migrator.registerMigration("v3_add_transcript_path") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "transcript_path", .text)
            }
        }

        migrator.registerMigration("v4_add_last_read_at") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "last_read_at", .datetime)
            }
            // Mark all existing sessions as read so upgrades don't flood with unread tags
            try db.execute(sql: "UPDATE sessions SET last_read_at = updated_at")
        }

        migrator.registerMigration("v5_add_git_info") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "git_repo_name", .text)
                t.add(column: "git_branch", .text)
            }
        }

        migrator.registerMigration("v6_add_last_reply") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "last_reply", .text)
            }
        }

        migrator.registerMigration("v7") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "launch_args", .text)
            }
        }

        migrator.registerMigration("v8_add_launch_directory") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "launch_directory", .text)
            }
            try db.execute(sql: "UPDATE sessions SET launch_directory = directory WHERE launch_directory IS NULL")
        }

        migrator.registerMigration("v9_add_host_workspace_folder") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "host_workspace_folder", .text)
            }
        }

        migrator.registerMigration("v10_create_remote_claude_code_sessions") { db in
            try db.create(table: "remote_claude_code_sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("model", .text).notNull()
                t.column("repo_url", .text)
                t.column("branches", .text).notNull().defaults(to: "[]")
                t.column("status", .text).notNull()
                t.column("worker_status", .text).notNull()
                t.column("connection_status", .text).notNull()
                t.column("last_event_at", .datetime).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("unread", .boolean).notNull()
            }
            try db.create(
                index: "idx_remote_claude_last_event_at",
                on: "remote_claude_code_sessions",
                columns: ["last_event_at"])
        }

        migrator.registerMigration("v11_add_remote_last_read_at") { db in
            try db.alter(table: "remote_claude_code_sessions") { t in
                t.add(column: "last_read_at", .datetime)
            }
        }

        migrator.registerMigration("v12_add_remote_environment_kind") { db in
            // Nullable at migration time so existing rows keep working; the
            // next API refresh backfills every row. `"bridge"` means the
            // session was imported from a local CLI; native claude.ai
            // sessions have a different (still-unobserved) value that will
            // flow through untouched.
            try db.alter(table: "remote_claude_code_sessions") { t in
                t.add(column: "environment_kind", .text).notNull().defaults(to: "")
            }
        }

        // v13: native-recall tables. Backs `SeshctlRecall.VectorStore` +
        // `Indexer`. Dedup is keyed on the COMPOSITE
        // `(text_hash, agent, session_id)` so that identical content from
        // different sessions both get indexed (e.g. a one-word reply like
        // "ok" appearing in many different chats) while same-session
        // re-walks collapse to a single row. `recall_embeddings.vector` is
        // a raw FP32 little-endian byte buffer (384 floats = 1536 bytes)
        // keyed by `entry_id` with FK cascade so wiping `recall_entries`
        // clears the embeddings too.
        migrator.registerMigration("v13_create_recall_tables") { db in
            try db.create(table: "recall_entries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("agent", .text).notNull()
                t.column("role", .text).notNull()
                t.column("session_id", .text).notNull()
                t.column("project", .text).notNull()
                t.column("timestamp", .double).notNull()
                t.column("text", .text).notNull()
                t.column("text_hash", .text).notNull()
                t.uniqueKey(["text_hash", "agent", "session_id"])
            }
            try db.create(table: "recall_embeddings") { t in
                t.column("entry_id", .integer)
                    .primaryKey()
                    .references("recall_entries", onDelete: .cascade)
                t.column("vector", .blob).notNull()
            }
            try db.create(table: "recall_cursors") { t in
                t.column("adapter_name", .text).primaryKey()
                t.column("cursor_json", .text).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(
                index: "recall_entries_timestamp", on: "recall_entries",
                columns: ["timestamp"])
            try db.create(
                index: "recall_entries_agent", on: "recall_entries",
                columns: ["agent"])
        }

        // v14: rebuild the recall_* tables so dev machines that already
        // ran the old v13 (with `text_hash UNIQUE`) get promoted to the
        // composite-UNIQUE schema. On fresh installs v14 is wasteful but
        // safe — it drops a table just created and recreates an identical
        // one. No data preservation is needed because the recall_* tables
        // are brand new in this PR and the index is rebuilt from
        // transcripts on first search after migration.
        migrator.registerMigration("v14_rebuild_recall_tables_for_composite_unique") { db in
            // FK cascade on `recall_embeddings.entry_id` clears embeddings
            // when entries drop. The defensive DROP on recall_embeddings
            // covers dev machines where cascade may not have fired.
            try db.execute(sql: "DROP TABLE IF EXISTS recall_entries")
            try db.execute(sql: "DROP TABLE IF EXISTS recall_embeddings")
            try db.execute(sql: "DROP TABLE IF EXISTS recall_cursors")

            try db.create(table: "recall_entries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("agent", .text).notNull()
                t.column("role", .text).notNull()
                t.column("session_id", .text).notNull()
                t.column("project", .text).notNull()
                t.column("timestamp", .double).notNull()
                t.column("text", .text).notNull()
                t.column("text_hash", .text).notNull()
                t.uniqueKey(["text_hash", "agent", "session_id"])
            }
            try db.create(table: "recall_embeddings") { t in
                t.column("entry_id", .integer)
                    .primaryKey()
                    .references("recall_entries", onDelete: .cascade)
                t.column("vector", .blob).notNull()
            }
            try db.create(table: "recall_cursors") { t in
                t.column("adapter_name", .text).primaryKey()
                t.column("cursor_json", .text).notNull()
                t.column("updated_at", .double).notNull()
            }
            try db.create(
                index: "recall_entries_timestamp", on: "recall_entries",
                columns: ["timestamp"])
            try db.create(
                index: "recall_entries_agent", on: "recall_entries",
                columns: ["agent"])
        }

        try migrator.migrate(dbPool)
    }

    // MARK: - Helpers

    private static let activeStatusFilter =
        Column("status") == SessionStatus.idle.rawValue
        || Column("status") == SessionStatus.working.rawValue
        || Column("status") == SessionStatus.waiting.rawValue

    // MARK: - Session Operations

    /// Find the active session for a given pid+tool.
    public func findActiveSession(pid: Int, tool: SessionTool) throws -> Session? {
        try dbPool.read { db in
            try Session
                .filter(Column("pid") == pid)
                .filter(Column("tool") == tool.rawValue)
                .filter(Self.activeStatusFilter)
                .fetchOne(db)
        }
    }

    /// Create a new session. If an active session exists for this pid+tool, end it first.
    @discardableResult
    public func startSession(
        tool: SessionTool, directory: String, pid: Int,
        conversationId: String? = nil,
        hostAppBundleId: String? = nil, hostAppName: String? = nil,
        windowId: String? = nil,
        transcriptPath: String? = nil,
        gitRepoName: String? = nil, gitBranch: String? = nil,
        launchArgs: String? = nil,
        launchDirectory: String? = nil,
        hostWorkspaceFolder: String? = nil
    ) throws -> Session {
        try dbPool.write { db in
            // End any existing active session for this pid+tool
            let existing = try Session
                .filter(Column("pid") == pid)
                .filter(Column("tool") == tool.rawValue)
                .filter(Self.activeStatusFilter)
                .fetchAll(db)

            let now = Date()
            for var session in existing {
                session.status = .completed
                session.updatedAt = now
                try session.update(db)
            }

            let session = Session(
                id: UUID().uuidString,
                conversationId: conversationId,
                tool: tool,
                directory: directory,
                launchDirectory: launchDirectory ?? directory,
                hostWorkspaceFolder: hostWorkspaceFolder,
                lastAsk: nil,
                lastReply: nil,
                status: .idle,
                pid: pid,
                hostAppBundleId: hostAppBundleId,
                hostAppName: hostAppName,
                windowId: windowId,
                transcriptPath: transcriptPath,
                gitRepoName: gitRepoName,
                gitBranch: gitBranch,
                launchArgs: launchArgs,
                startedAt: now,
                updatedAt: now,
                lastReadAt: now
            )
            try session.insert(db)
            return session
        }
    }

    /// Update the active session for a pid+tool. Creates one if none exists (idempotent).
    @discardableResult
    public func updateSession(
        pid: Int, tool: SessionTool,
        ask: String? = nil, reply: String? = nil,
        status: SessionStatus? = nil,
        transcriptPath: String? = nil,
        conversationId: String? = nil, directory: String? = nil,
        gitRepoName: String? = nil, gitBranch: String? = nil,
        hostAppBundleId: String? = nil, hostAppName: String? = nil
    ) throws -> Session {
        try dbPool.write { db in
            let now = Date()

            if var session = try Session
                .filter(Column("pid") == pid)
                .filter(Column("tool") == tool.rawValue)
                .filter(Self.activeStatusFilter)
                .fetchOne(db)
            {
                if let ask {
                    let truncated = String(ask.prefix(500))
                    session.lastAsk = truncated
                }
                if let reply {
                    let truncated = String(reply.prefix(500))
                    session.lastReply = truncated
                }
                if let status {
                    // Only allow .waiting from .working. PreToolUse sets
                    // working before every tool call, so Notification always
                    // sees working state. A late Notification after Stop
                    // (idle) is stale and must be ignored.
                    let skip = status == .waiting && session.status != .working
                    if !skip {
                        session.status = status
                    }
                }
                if let transcriptPath {
                    session.transcriptPath = transcriptPath
                }
                if let conversationId {
                    session.conversationId = conversationId
                }
                if let directory {
                    session.directory = directory
                }
                if let gitRepoName {
                    session.gitRepoName = gitRepoName
                }
                if let gitBranch {
                    session.gitBranch = gitBranch
                }
                // Fill host-app fields only when empty — first writer wins.
                // A later hook event may supply these when the original
                // lazy-create lacked them; never overwrite a value set by
                // an earlier start/update.
                if let hostAppBundleId, session.hostAppBundleId == nil {
                    session.hostAppBundleId = hostAppBundleId
                }
                if let hostAppName, session.hostAppName == nil {
                    session.hostAppName = hostAppName
                }
                session.updatedAt = now
                try session.update(db)
                return session
            }

            // No active session — create one
            let session = Session(
                id: UUID().uuidString,
                conversationId: conversationId,
                tool: tool,
                directory: directory ?? FileManager.default.currentDirectoryPath,
                launchDirectory: nil,
                hostWorkspaceFolder: nil,
                lastAsk: ask.map { String($0.prefix(500)) },
                lastReply: reply.map { String($0.prefix(500)) },
                status: status ?? .idle,
                pid: pid,
                hostAppBundleId: hostAppBundleId,
                hostAppName: hostAppName,
                windowId: nil,
                transcriptPath: transcriptPath,
                gitRepoName: gitRepoName,
                gitBranch: gitBranch,
                launchArgs: nil,
                startedAt: now,
                updatedAt: now,
                lastReadAt: now
            )
            try session.insert(db)
            return session
        }
    }

    /// End the active session for a pid+tool.
    public func endSession(pid: Int, tool: SessionTool, status: SessionStatus = .completed) throws {
        try dbPool.write { db in
            if var session = try Session
                .filter(Column("pid") == pid)
                .filter(Column("tool") == tool.rawValue)
                .filter(Self.activeStatusFilter)
                .fetchOne(db)
            {
                session.status = status
                session.updatedAt = Date()
                try session.update(db)
            }
        }
    }

    // MARK: - Conversation-ID-Keyed Session Operations
    //
    // These mirror the pid-keyed methods above but match on `conversation_id`
    // instead. Required for tools whose hook subprocess PIDs are not stable
    // across events (e.g. Cursor 1.7+, where each hook is a fresh
    // `/bin/zsh -c` subprocess). The conversation_id is provided by the tool
    // and is stable for the lifetime of a conversation.

    /// Find the active session for a given conversationId+tool.
    public func findActiveSession(conversationId: String, tool: SessionTool) throws -> Session? {
        try dbPool.read { db in
            try Session
                .filter(Column("conversation_id") == conversationId)
                .filter(Column("tool") == tool.rawValue)
                .filter(Self.activeStatusFilter)
                .fetchOne(db)
        }
    }

    /// Create a new session keyed on conversationId+tool. If an active session
    /// exists for this conversationId+tool, end it first. Mirrors the pid-keyed
    /// `startSession`'s "end-then-insert" pattern, but uses conversation_id as
    /// the match key so it never disturbs an unrelated row that happens to
    /// share a PPID (e.g. Cursor 1.7+ hooks fire from fresh `/bin/zsh -c`
    /// subprocesses whose PPIDs can coincide across conversations over a long
    /// Cursor lifetime).
    @discardableResult
    public func startSession(
        conversationId: String,
        tool: SessionTool,
        directory: String,
        hostAppBundleId: String? = nil, hostAppName: String? = nil,
        windowId: String? = nil,
        transcriptPath: String? = nil,
        gitRepoName: String? = nil, gitBranch: String? = nil,
        launchArgs: String? = nil,
        launchDirectory: String? = nil,
        hostWorkspaceFolder: String? = nil
    ) throws -> Session {
        try dbPool.write { db in
            // End any existing active session for this conversationId+tool.
            // Do NOT match on pid — coincident PPIDs across conversations
            // must not collapse two distinct rows.
            let existing = try Session
                .filter(Column("conversation_id") == conversationId)
                .filter(Column("tool") == tool.rawValue)
                .filter(Self.activeStatusFilter)
                .fetchAll(db)

            let now = Date()
            for var session in existing {
                session.status = .completed
                session.updatedAt = now
                try session.update(db)
            }

            let session = Session(
                id: UUID().uuidString,
                conversationId: conversationId,
                tool: tool,
                directory: directory,
                launchDirectory: launchDirectory ?? directory,
                hostWorkspaceFolder: hostWorkspaceFolder,
                lastAsk: nil,
                lastReply: nil,
                status: .idle,
                pid: nil,
                hostAppBundleId: hostAppBundleId,
                hostAppName: hostAppName,
                windowId: windowId,
                transcriptPath: transcriptPath,
                gitRepoName: gitRepoName,
                gitBranch: gitBranch,
                launchArgs: launchArgs,
                startedAt: now,
                updatedAt: now,
                lastReadAt: now
            )
            try session.insert(db)
            return session
        }
    }

    /// Update the active session for a conversationId+tool. Creates one if
    /// none exists (idempotent), with `pid: nil` since callers using this
    /// path don't have a stable PID to record.
    @discardableResult
    public func updateSession(
        conversationId: String, tool: SessionTool,
        ask: String? = nil, reply: String? = nil,
        status: SessionStatus? = nil,
        transcriptPath: String? = nil,
        directory: String? = nil,
        gitRepoName: String? = nil, gitBranch: String? = nil,
        hostAppBundleId: String? = nil, hostAppName: String? = nil
    ) throws -> Session {
        try dbPool.write { db in
            let now = Date()

            if var session = try Session
                .filter(Column("conversation_id") == conversationId)
                .filter(Column("tool") == tool.rawValue)
                .filter(Self.activeStatusFilter)
                .fetchOne(db)
            {
                if let ask {
                    let truncated = String(ask.prefix(500))
                    session.lastAsk = truncated
                }
                if let reply {
                    let truncated = String(reply.prefix(500))
                    session.lastReply = truncated
                }
                if let status {
                    // Only allow .waiting from .working. PreToolUse sets
                    // working before every tool call, so Notification always
                    // sees working state. A late Notification after Stop
                    // (idle) is stale and must be ignored.
                    let skip = status == .waiting && session.status != .working
                    if !skip {
                        session.status = status
                    }
                }
                if let transcriptPath {
                    session.transcriptPath = transcriptPath
                }
                if let directory {
                    session.directory = directory
                }
                if let gitRepoName {
                    session.gitRepoName = gitRepoName
                }
                if let gitBranch {
                    session.gitBranch = gitBranch
                }
                // Fill host-app fields only when empty — first writer wins.
                // The very first event for a missed-sessionStart conversation
                // will lazy-create with these populated; subsequent events
                // re-pass them but won't clobber.
                if let hostAppBundleId, session.hostAppBundleId == nil {
                    session.hostAppBundleId = hostAppBundleId
                }
                if let hostAppName, session.hostAppName == nil {
                    session.hostAppName = hostAppName
                }
                session.updatedAt = now
                try session.update(db)
                return session
            }

            // No active session — lazy-create one. pid stays nil because the
            // caller doesn't have a stable PID for this tool.
            let session = Session(
                id: UUID().uuidString,
                conversationId: conversationId,
                tool: tool,
                directory: directory ?? FileManager.default.currentDirectoryPath,
                launchDirectory: nil,
                hostWorkspaceFolder: nil,
                lastAsk: ask.map { String($0.prefix(500)) },
                lastReply: reply.map { String($0.prefix(500)) },
                status: status ?? .idle,
                pid: nil,
                hostAppBundleId: hostAppBundleId,
                hostAppName: hostAppName,
                windowId: nil,
                transcriptPath: transcriptPath,
                gitRepoName: gitRepoName,
                gitBranch: gitBranch,
                launchArgs: nil,
                startedAt: now,
                updatedAt: now,
                lastReadAt: now
            )
            try session.insert(db)
            return session
        }
    }

    /// End the active session for a conversationId+tool.
    public func endSession(conversationId: String, tool: SessionTool, status: SessionStatus = .completed) throws {
        try dbPool.write { db in
            if var session = try Session
                .filter(Column("conversation_id") == conversationId)
                .filter(Column("tool") == tool.rawValue)
                .filter(Self.activeStatusFilter)
                .fetchOne(db)
            {
                session.status = status
                session.updatedAt = Date()
                try session.update(db)
            }
        }
    }

    /// List sessions ordered by updated_at DESC.
    public func listSessions(
        limit: Int = 20, status: SessionStatus? = nil, tool: SessionTool? = nil
    ) throws -> [Session] {
        try dbPool.read { db in
            var query = Session.order(Column("updated_at").desc)
            if let status {
                query = query.filter(Column("status") == status.rawValue)
            }
            if let tool {
                query = query.filter(Column("tool") == tool.rawValue)
            }
            return try query.limit(limit).fetchAll(db)
        }
    }

    /// Fetch a single session by ID.
    public func getSession(id: String) throws -> Session? {
        try dbPool.read { db in
            try Session.fetchOne(db, key: id)
        }
    }

    /// Mark a session as read by setting last_read_at to now.
    public func markSessionRead(id: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE sessions SET last_read_at = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    /// Fast check: mark active sessions with dead PIDs as stale.
    /// Intended to run every poll cycle for responsive cleanup.
    @discardableResult
    public func reapStaleSessions(isProcessAlive: (Int) -> Bool = { pid in
        kill(Int32(pid), 0) == 0
    }) throws -> Int {
        try dbPool.write { db in
            let activeSessions = try Session
                .filter(Self.activeStatusFilter)
                .fetchAll(db)

            var markedStale = 0
            for var session in activeSessions {
                if let pid = session.pid, !isProcessAlive(pid) {
                    session.status = .stale
                    session.updatedAt = Date()
                    try session.update(db)
                    markedStale += 1
                }
            }
            return markedStale
        }
    }

    /// Garbage collect: delete old completed sessions and mark stale ones.
    /// Returns (deleted, marked_stale) counts.
    @discardableResult
    public func gc(olderThan: TimeInterval = 30 * 24 * 3600, isProcessAlive: (Int) -> Bool = { pid in
        kill(Int32(pid), 0) == 0
    }) throws -> (deleted: Int, markedStale: Int) {
        try dbPool.write { db in
            let cutoff = Date().addingTimeInterval(-olderThan)

            // Delete old completed/canceled/stale sessions
            let deleted = try Session
                .filter(Column("status") == SessionStatus.completed.rawValue
                    || Column("status") == SessionStatus.canceled.rawValue
                    || Column("status") == SessionStatus.stale.rawValue)
                .filter(Column("updated_at") < cutoff)
                .deleteAll(db)

            // Mark stale: active sessions whose PID is dead
            let activeSessions = try Session
                .filter(Self.activeStatusFilter)
                .fetchAll(db)

            var markedStale = 0
            for var session in activeSessions {
                if let pid = session.pid, !isProcessAlive(pid) {
                    session.status = .stale
                    session.updatedAt = Date()
                    try session.update(db)
                    markedStale += 1
                }
            }

            return (deleted: deleted, markedStale: markedStale)
        }
    }

    // MARK: - Remote Claude Code Session Operations

    /// Replace-all semantics for remote Claude Code sessions.
    ///
    /// In a single write transaction: (1) delete rows whose id is NOT in the
    /// input set, then (2) upsert every input session. This mirrors the
    /// server's view — archived/deleted cloud sessions disappear locally on
    /// the next refresh.
    public func upsertRemoteClaudeCodeSessions(_ sessions: [RemoteClaudeCodeSession]) throws {
        try dbPool.write { db in
            let ids = sessions.map(\.id)
            if ids.isEmpty {
                try db.execute(sql: "DELETE FROM remote_claude_code_sessions")
            } else {
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM remote_claude_code_sessions WHERE id NOT IN (\(placeholders))",
                    arguments: StatementArguments(ids)
                )
            }
            for session in sessions {
                try session.save(db)
            }
        }
    }

    /// Mark a remote Claude Code session as read by stamping last_read_at. The
    /// row's API-reported `unread` flag is left untouched; `RemoteClaudeCodeSession.isUnread`
    /// combines both (a locally-marked read wins until a newer `last_event_at`
    /// arrives).
    public func markRemoteClaudeCodeSessionRead(id: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE remote_claude_code_sessions SET last_read_at = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    /// List all remote Claude Code sessions ordered by last_event_at DESC.
    public func listRemoteClaudeCodeSessions() throws -> [RemoteClaudeCodeSession] {
        try dbPool.read { db in
            try RemoteClaudeCodeSession
                .order(Column("last_event_at").desc)
                .fetchAll(db)
        }
    }

    /// Delete all cached remote Claude Code sessions. Used by Disconnect.
    public func clearRemoteClaudeCodeSessions() throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM remote_claude_code_sessions")
        }
    }
}
