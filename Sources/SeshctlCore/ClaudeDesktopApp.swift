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
        let suffix = id.unicodeScalars.dropFirst(prefix.unicodeScalars.count)
        guard !suffix.isEmpty else { return false }
        return suffix.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-": return true
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
        let suffix = id.unicodeScalars.dropFirst(prefix.unicodeScalars.count)
        guard (1...64).contains(suffix.count) else { return false }
        return suffix.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "-": return true
            default: return false
            }
        }
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

    /// The desktop app's `local_…` id for the session whose CLI conversation
    /// id is `cliSessionId`, or `nil` when no live (non-archived) session
    /// file matches. Matches `cliSessionId` or `lastAssistantCliSessionId`.
    /// Session files are ~100 KB, so each is checked for the id's bytes
    /// before it's decoded.
    public static func localSessionId(
        forCliSessionId cliSessionId: String,
        sessionsRoot: URL = defaultLocalSessionsRoot
    ) -> String? {
        guard !cliSessionId.isEmpty, let needle = cliSessionId.data(using: .utf8) else { return nil }
        let fm = FileManager.default
        let dirs = { (url: URL) -> [URL] in
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        for account in dirs(sessionsRoot) {
            for org in dirs(account) {
                let files = (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: file), data.range(of: needle) != nil,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          json["cliSessionId"] as? String == cliSessionId
                            || json["lastAssistantCliSessionId"] as? String == cliSessionId,
                          json["isArchived"] as? Bool != true,
                          let id = json["sessionId"] as? String, isValidLocalSessionId(id)
                    else { continue }
                    return id
                }
            }
        }
        return nil
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
