import Foundation
import GRDB

/// A Claude Code session hosted in claude.ai (Cowork).
///
/// Fetched from the claude.ai internal API and cached in the local SQLite DB
/// for display alongside local sessions. Intentionally does NOT conform to
/// `Codable` — the API response shape is nested (`config.model`,
/// `config.outcomes[].git_info.branches`, etc.) and flattening happens in a
/// separate API-response type. Manual GRDB bridging below stores `branches`
/// as a JSON-encoded TEXT column (SQLite has no array type).
public struct RemoteClaudeCodeSession: FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var model: String
    public var repoUrl: String?
    public var branches: [String]
    public var status: String
    public var workerStatus: String
    public var connectionStatus: String
    public var lastEventAt: Date
    public var createdAt: Date
    /// API-reported unread flag. Use `isUnread` for display — it combines this
    /// with `lastReadAt` so a locally-marked read survives the next refresh.
    public var unread: Bool
    /// When the user last pressed `u` on this row. Never written back to the DB
    /// via `save()` — `encode(to:)` intentionally omits it so `upsert` preserves
    /// the column across refreshes. Mutated only via
    /// `Database.markRemoteClaudeCodeSessionRead(id:)`.
    public var lastReadAt: Date?
    /// `"bridge"` for sessions that were imported from a local Claude Code
    /// CLI (the desktop app's sessions-bridge). Other values — expected to
    /// mean "native cloud session" — flow through untouched. Used by the
    /// local/remote dedupe matcher: only `bridge` rows are candidates for
    /// twinning with a local `Session`.
    public var environmentKind: String

    public static let databaseTableName = "remote_claude_code_sessions"

    /// Display-side unread. True when the API says unread AND either the row
    /// has never been marked read locally, or new activity has landed since it
    /// was marked read.
    public var isUnread: Bool {
        guard unread else { return false }
        guard let lastReadAt else { return true }
        return lastEventAt > lastReadAt
    }

    /// claude.ai deep-link. The API returns ids like `cse_<uuid>` but the
    /// web path uses `session_<uuid>` — same UUID, different prefix.
    public var webUrl: URL {
        let suffix = id.hasPrefix("cse_") ? String(id.dropFirst("cse_".count)) : id
        return URL(string: "https://claude.ai/code/session_\(suffix)")!
    }

    public init(
        id: String,
        title: String,
        model: String,
        repoUrl: String?,
        branches: [String],
        status: String,
        workerStatus: String,
        connectionStatus: String,
        lastEventAt: Date,
        createdAt: Date,
        unread: Bool,
        lastReadAt: Date? = nil,
        environmentKind: String = ""
    ) {
        self.id = id
        self.title = title
        self.model = model
        self.repoUrl = repoUrl
        self.branches = branches
        self.status = status
        self.workerStatus = workerStatus
        self.connectionStatus = connectionStatus
        self.lastEventAt = lastEventAt
        self.createdAt = createdAt
        self.unread = unread
        self.lastReadAt = lastReadAt
        self.environmentKind = environmentKind
    }

    public init(row: Row) throws {
        id = row["id"]
        title = row["title"]
        model = row["model"]
        repoUrl = row["repo_url"]
        let branchesJson: String = row["branches"] ?? "[]"
        branches = (try? JSONDecoder().decode([String].self, from: Data(branchesJson.utf8))) ?? []
        status = row["status"]
        workerStatus = row["worker_status"]
        connectionStatus = row["connection_status"]
        lastEventAt = row["last_event_at"]
        createdAt = row["created_at"]
        unread = row["unread"]
        lastReadAt = row["last_read_at"]
        environmentKind = row["environment_kind"] ?? ""
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["title"] = title
        container["model"] = model
        container["repo_url"] = repoUrl
        let branchesData = (try? JSONEncoder().encode(branches)) ?? Data("[]".utf8)
        container["branches"] = String(data: branchesData, encoding: .utf8) ?? "[]"
        container["status"] = status
        container["worker_status"] = workerStatus
        container["connection_status"] = connectionStatus
        container["last_event_at"] = lastEventAt
        container["created_at"] = createdAt
        container["unread"] = unread
        container["environment_kind"] = environmentKind
        // Intentionally omit `last_read_at`: it's a local-only read receipt
        // that must survive the replace-all upsert from the API. GRDB uses this
        // container for both INSERT and UPDATE, and omitting the column keeps
        // existing values intact on upsert and defaults to NULL on insert.
    }
}
