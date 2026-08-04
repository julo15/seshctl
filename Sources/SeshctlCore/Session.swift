import Foundation
import GRDB

public enum SessionStatus: String, Codable, DatabaseValueConvertible, Sendable {
    case idle
    case working
    case waiting
    case completed
    case canceled
    case stale
}

/// `CaseIterable` so per-tool registries (display name, badge spec) can be
/// tested exhaustively — adding a case without naming it fails a test rather
/// than silently rendering blank. AGENTS.md's "Adding an LLM Tool" checklist
/// assumes this conformance.
public enum SessionTool: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    case claude
    case gemini
    case codex
    case cursor
    case pi
}

public struct Session: Codable, Sendable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public var id: String
    public var conversationId: String?
    public var tool: SessionTool
    public var directory: String
    public var launchDirectory: String?
    public var hostWorkspaceFolder: String?
    public var lastAsk: String?
    public var lastReply: String?
    public var status: SessionStatus
    public var pid: Int?
    public var hostAppBundleId: String?
    public var hostAppName: String?
    public var windowId: String?
    public var transcriptPath: String?
    public var gitRepoName: String?
    public var gitBranch: String?
    public var launchArgs: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var lastReadAt: Date?
    /// Frozen thread title, in the style of a chat app naming a conversation.
    /// Generated once from the session's opening exchange and then left alone,
    /// so the row keeps a stable identity instead of tracking whatever was
    /// said most recently. Nil until generation succeeds; regenerated only on
    /// explicit user request. See `SessionTitler`.
    public var title: String?
    /// When `title` was last written. Distinguishes "never attempted" from
    /// "attempted and failed", which is what stops a failing titler from
    /// retrying on every refresh.
    public var titleUpdatedAt: Date?

    public static let databaseTableName = "sessions"

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case tool
        case directory
        case launchDirectory = "launch_directory"
        case hostWorkspaceFolder = "host_workspace_folder"
        case lastAsk = "last_ask"
        case lastReply = "last_reply"
        case status
        case pid
        case hostAppBundleId = "host_app_bundle_id"
        case hostAppName = "host_app_name"
        case windowId = "window_id"
        case transcriptPath = "transcript_path"
        case gitRepoName = "git_repo_name"
        case gitBranch = "git_branch"
        case launchArgs = "launch_args"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case lastReadAt = "last_read_at"
        case title
        case titleUpdatedAt = "title_updated_at"
    }

    public var isActive: Bool {
        status == .idle || status == .working || status == .waiting
    }

    public var displayName: String {
        let dirName = (directory as NSString).lastPathComponent

        guard let repoName = gitRepoName else {
            return dirName
        }

        var parts = [repoName]

        if dirName != repoName {
            parts.append(dirName)
        }

        if let branch = gitBranch {
            parts.append(branch)
        }

        return parts.joined(separator: " · ")
    }
}
