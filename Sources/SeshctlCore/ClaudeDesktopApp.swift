import Foundation

/// Registry for the Claude desktop app (`/Applications/Claude.app`).
///
/// Single source of truth for its bundle ID, URL scheme, and the deep link
/// that opens a Claude Code session inside it. The desktop app is neither a
/// `TerminalApp` (it hosts no shell, so there's no tab or TTY to match) nor a
/// `BrowserApp` (we don't walk its tabs), so it gets its own small type.
/// Foundation-only.
///
/// It also hosts *local* Code sessions: the app runs the `claude` CLI
/// itself, so the hooks record those sessions with this bundle ID as the
/// host app. `continueURL(localSessionId:)` focuses one of them.
///
/// The `claude://code/<session-id>` route is **undocumented** — it was found
/// by reading the app's bundled JavaScript and verified by hand on desktop
/// 3.1623.4. A desktop update could change or remove it, and `open` reports
/// success even when the app ignores a route, so callers must keep the
/// browser path as the fallback for when the app isn't installed.
public enum ClaudeDesktopApp {
    public static let bundleId = "com.anthropic.claudefordesktop"
    public static let scheme = "claude"

    /// Accepted session-id prefixes. Mirrors the desktop app's own validator,
    /// `/^(cse|session)_[A-Za-z0-9_-]+$/`.
    private static let sessionIdPrefixes = ["cse_", "session_"]

    /// True when `id` matches `^(cse|session)_[A-Za-z0-9_-]+$`. Session ids
    /// come from an API response, so this gate runs before any id is
    /// interpolated into a URL.
    public static func isValidSessionId(_ id: String) -> Bool {
        guard let prefix = sessionIdPrefixes.first(where: { id.hasPrefix($0) }) else { return false }
        return isValidSuffix(of: id, prefix: prefix, allowsUnderscore: true, maxLength: nil)
    }

    /// True when `id` minus `prefix` is non-empty, at most `maxLength`
    /// scalars, and only ASCII letters, digits, `-`, and `_` if allowed.
    private static func isValidSuffix(of id: String, prefix: String, allowsUnderscore: Bool, maxLength: Int?) -> Bool {
        let suffix = id.unicodeScalars.dropFirst(prefix.unicodeScalars.count)
        guard !suffix.isEmpty, suffix.count <= (maxLength ?? .max) else { return false }
        return suffix.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "-": return true
            case "_": return allowsUnderscore
            default: return false
            }
        }
    }

    /// `claude://code/<id>` for a `cse_…` or `session_…` id, or `nil` if the
    /// id fails `isValidSessionId`.
    public static func sessionURL(for id: String) -> URL? {
        guard isValidSessionId(id) else { return nil }
        return URL(string: "\(scheme)://code/\(id)")
    }

    // MARK: - Local (desktop-hosted) Code sessions

    /// Where the desktop app keeps one metadata file per local Code session:
    /// `<root>/<account>/<org>/local_<uuid>.json`. Each file maps the app's
    /// own id (`sessionId`, `local_…`) to the CLI's conversation id
    /// (`cliSessionId`) — the id seshctl records from the hooks.
    public static var defaultLocalSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// True when `id` matches the desktop app's local-session validator,
    /// `/^local_[A-Za-z0-9-]{1,64}$/`. Ids come from files on disk, so this
    /// gate runs before any id is interpolated into a URL.
    public static func isValidLocalSessionId(_ id: String) -> Bool {
        let prefix = "local_"
        guard id.hasPrefix(prefix) else { return false }
        return isValidSuffix(of: id, prefix: prefix, allowsUnderscore: false, maxLength: 64)
    }

    /// `claude://code/continue?session=<id>`, which switches the desktop
    /// app's window to that local session. `nil` when the id fails
    /// `isValidLocalSessionId`. Undocumented like `sessionURL(for:)`: found
    /// in the app's bundled JavaScript and verified on desktop 5.11492.5.
    /// The app ignores it for archived sessions (it opens the Code home).
    public static func continueURL(localSessionId id: String) -> URL? {
        guard isValidLocalSessionId(id) else { return nil }
        return URL(string: "\(scheme)://code/continue?session=\(id)")
    }

    /// Session files larger than this are skipped unread. Real ones are
    /// ~100 KB; the cap bounds the main-thread read on Enter.
    static let maxSessionFileSize = 5 * 1024 * 1024

    /// The desktop app's `local_…` id for the session that `cliSessionId`
    /// belongs to, or `nil` when no live (non-archived) session file matches.
    ///
    /// A session's current CLI ids (`cliSessionId`, `lastAssistantCliSessionId`)
    /// win over ids it held earlier (`priorCliSessionIds`, after `/clear` or a
    /// resume, and `historyOnlyCliSessionId`). Within each tier the most
    /// recently modified file wins. Files are read newest first and checked
    /// for the id's bytes before they're decoded, so a current match in a
    /// recent session usually costs one file read.
    public static func localSessionId(
        forCliSessionId cliSessionId: String,
        sessionsRoot: URL = defaultLocalSessionsRoot
    ) -> String? {
        guard !cliSessionId.isEmpty, let needle = cliSessionId.data(using: .utf8) else { return nil }
        var priorMatch: String?
        for file in sessionFiles(under: sessionsRoot) {
            guard let data = try? Data(contentsOf: file), data.range(of: needle) != nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["isArchived"] as? Bool != true,
                  let id = json["sessionId"] as? String, isValidLocalSessionId(id)
            else { continue }
            if json["cliSessionId"] as? String == cliSessionId
                || json["lastAssistantCliSessionId"] as? String == cliSessionId {
                return id
            }
            if priorMatch == nil, priorCliSessionIds(in: json).contains(cliSessionId) {
                priorMatch = id
            }
        }
        return priorMatch
    }

    /// Ids a session held before its current one. `historyOnlyCliSessionId`
    /// is read as a string or an array, since the app wraps it either way.
    private static func priorCliSessionIds(in json: [String: Any]) -> [String] {
        var ids = json["priorCliSessionIds"] as? [String] ?? []
        if let historyOnly = json["historyOnlyCliSessionId"] as? String {
            ids.append(historyOnly)
        } else if let historyOnly = json["historyOnlyCliSessionId"] as? [String] {
            ids += historyOnly
        }
        return ids
    }

    /// `<root>/<account>/<org>/local_*.json`, regular files no larger than
    /// `maxSessionFileSize`, most recently modified first.
    static func sessionFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let children = { (url: URL) -> [URL] in
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        }
        let isDirectory = { (url: URL) in (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        var files: [(url: URL, modified: Date)] = []
        for account in children(root) where isDirectory(account) {
            for org in children(account) where isDirectory(org) {
                for file in children(org) where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    guard let values = try? file.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true,
                          (values.fileSize ?? 0) <= maxSessionFileSize
                    else { continue }
                    files.append((file, values.contentModificationDate ?? .distantPast))
                }
            }
        }
        return files.sorted { $0.modified > $1.modified }.map(\.url)
    }

    /// Derive the desktop deep link from a claude.ai web URL of the form
    /// `https://claude.ai/code/session_<SUFFIX>` (what
    /// `RemoteClaudeCodeSession.webUrl` produces). Returns `nil` for any other
    /// shape, so callers fall back to opening the web URL.
    public static func sessionURL(fromWebURL url: URL) -> URL? {
        guard url.scheme == "https", url.host == "claude.ai" else { return nil }
        let components = url.pathComponents
        guard components.count == 3, components[0] == "/", components[1] == "code" else { return nil }
        return sessionURL(for: components[2])
    }
}
