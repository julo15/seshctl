import Foundation

/// Registry for the Claude desktop app (`/Applications/Claude.app`).
///
/// Single source of truth for its bundle ID, URL scheme, and the deep link
/// that opens a Claude Code session inside it. The desktop app is neither a
/// `TerminalApp` (it hosts no shell sessions we focus) nor a `BrowserApp` (we
/// don't walk its tabs), so it gets its own small type. Foundation-only.
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
