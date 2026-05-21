import Foundation
import OSLog

// MARK: - Cookie source

/// Abstraction over a cookie source so tests can inject cookies without needing
/// `WKHTTPCookieStore`. The app layer builds a `ClosureCookieSource` that wraps
/// `WKWebsiteDataStore.default().httpCookieStore.allCookies()`; tests build a
/// `ClosureCookieSource` returning a fixed array.
public protocol ClaudeCookieSource: Sendable {
    func currentCookies() async -> [HTTPCookie]
}

/// Concrete `ClaudeCookieSource` that defers to a closure. Kept in
/// `SeshctlCore` — and WebKit-free — so this target does not depend on WebKit.
public struct ClosureCookieSource: ClaudeCookieSource {
    let provider: @Sendable () async -> [HTTPCookie]

    public init(_ provider: @escaping @Sendable () async -> [HTTPCookie]) {
        self.provider = provider
    }

    public func currentCookies() async -> [HTTPCookie] {
        await provider()
    }
}

// MARK: - Errors

/// Error surface for `RemoteClaudeCodeFetcher.refresh()`. `Equatable` so tests
/// can compare cases (and the associated `Int`/`String` values) directly.
public enum RemoteClaudeCodeError: Error, Equatable {
    /// Required cookies (`sessionKey` + `sessionKeyLC`) are missing.
    case notConnected
    /// Server rejected the request with 401. The caller should prompt re-auth.
    case needsReauth
    /// Any non-200/401 HTTP status.
    case http(Int)
    /// Response decoded to malformed JSON.
    case decode(String)
    /// URLSession-level failure (no HTTP response, URLError, etc.).
    case transport(String)
}

// MARK: - API response types

/// Top-level shape of `GET /v1/code/sessions?limit=50`.
struct APIListResponse: Decodable {
    let data: [APISession]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextCursor = "next_cursor"
    }
}

/// One session entry as returned by the claude.ai API. Only the fields we care
/// about are modeled; extra fields are ignored by the `Decodable` synthesizer.
struct APISession: Decodable {
    let id: String
    let title: String
    let status: String
    let workerStatus: String
    let connectionStatus: String
    let createdAt: Date
    let lastEventAt: Date
    let unread: Bool
    let config: APIConfig
    /// `"bridge"` for CLI-bridged sessions; absent or another value for
    /// native cloud sessions. Optional to accept three API shapes that all
    /// flatten to the same `""` default: field missing, field explicitly
    /// `null`, or field present with some other value we haven't observed
    /// yet. Older captured fixtures (pre-bridge field) also decode cleanly.
    let environmentKind: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case workerStatus = "worker_status"
        case connectionStatus = "connection_status"
        case createdAt = "created_at"
        case lastEventAt = "last_event_at"
        case unread
        case config
        case environmentKind = "environment_kind"
    }
}

struct APIConfig: Decodable {
    /// Optional: some sessions (observed in live API responses) omit `model`.
    let model: String?
    let sources: [APISource]
    /// Optional: older sessions may not have this key.
    let outcomes: [APIOutcome]?
}

struct APISource: Decodable {
    let type: String
    let url: String?
    // `revision`, `allow_unrestricted_git_push`, `sparse_checkout_paths` are
    // intentionally ignored — Decodable-synthesized init skips unmapped keys.
}

struct APIOutcome: Decodable {
    let type: String
    let gitInfo: APIGitInfo?

    enum CodingKeys: String, CodingKey {
        case type
        case gitInfo = "git_info"
    }
}

struct APIGitInfo: Decodable {
    let branches: [String]
    // `type` and `repo` are intentionally ignored.
}

// MARK: - Flatten

/// Worker-status values the app currently handles. Derived from the
/// `RemoteWorkerStatus` enum so adding or renaming a case can never drift out
/// of sync with the fetcher's "is this status known?" check. Anything outside
/// this set is logged at refresh time (see `fetcherLogger`) so we can
/// discover new states in the wild.
fileprivate let knownWorkerStatuses: Set<String> = Set(
    RemoteWorkerStatus.allCases.map(\.rawValue)
)

/// Logger for fetcher diagnostics. Prefer this over `fputs(stderr)` — the app
/// ships as a launchd-managed menu-bar binary whose stderr is typically
/// discarded, so `os_log` output via `log stream --predicate 'subsystem ==
/// "app.seshctl"'` (or Console.app) is the only reliable way to surface
/// discovery signals like "unknown worker_status value seen in the wild."
fileprivate let fetcherLogger = Logger(subsystem: "app.seshctl", category: "remote-fetcher")

/// Maps one API session to the flat DB-shaped `RemoteClaudeCodeSession`.
///
/// - `model` comes from `config.model`.
/// - `repoUrl` is the first `git_repository` source URL (nil if none).
/// - `branches` is the first outcome's `git_info.branches`, or `[]` if missing.
/// - `lastReadAt` is always nil here; the upsert preserves the existing
///   column value, so this nil never clobbers a prior local mark-as-read.
func flattenAPISession(_ api: APISession) -> RemoteClaudeCodeSession {
    let repoUrl = api.config.sources.first(where: { $0.type == "git_repository" })?.url
    let branches = api.config.outcomes?.first?.gitInfo?.branches ?? []
    return RemoteClaudeCodeSession(
        id: api.id,
        title: api.title,
        model: api.config.model ?? "",
        repoUrl: repoUrl,
        branches: branches,
        status: api.status,
        workerStatus: api.workerStatus,
        connectionStatus: api.connectionStatus,
        lastEventAt: api.lastEventAt,
        createdAt: api.createdAt,
        unread: api.unread,
        lastReadAt: nil,
        environmentKind: api.environmentKind ?? ""
    )
}

// MARK: - Request building

/// Builds a `GET` request to a claude.ai endpoint with the canonical
/// header set the backend expects: Cookie + anthropic-beta + anthropic-version
/// + Origin + Referer + Safari UA + Accept. Extracted as a pure helper so
/// every claude.ai endpoint we hit (list, per-session events, future) shares
/// one header definition.
func buildAuthedRequest(url: URL, cookieHeader: String) -> URLRequest {
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    req.setValue("managed-agents-2026-04-01", forHTTPHeaderField: "anthropic-beta")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
    req.setValue("https://claude.ai/code", forHTTPHeaderField: "Referer")
    req.setValue(RemoteClaudeCodeFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    return req
}

/// Builds the `GET /v1/code/sessions?limit=50` request with all required
/// headers. Extracted as a pure helper so tests can exercise header shape
/// without an actor hop.
func buildRemoteClaudeCodeRequest(cookieHeader: String) -> URLRequest {
    // swiftlint:disable:next force_unwrapping — constant, always valid
    let url = URL(string: "https://claude.ai/v1/code/sessions?limit=50")!
    return buildAuthedRequest(url: url, cookieHeader: cookieHeader)
}

/// JSONDecoder configured to parse ISO8601 timestamps with fractional seconds
/// (e.g. `"2026-04-15T01:40:25.669139Z"`). The stdlib `.iso8601` strategy
/// rejects fractional seconds, so we install a custom strategy.
///
/// Formatters are built fresh per decode — `ISO8601DateFormatter` is not
/// `Sendable`, and the decoding closure is `@Sendable`. Constructing them in
/// the closure sidesteps that without caching complexity; a session list
/// response is at most 50 dates, negligible cost.
func makeClaudeJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { d in
        let container = try d.singleValueContainer()
        let string = try container.decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unrecognized ISO8601 date: \(string)"
        )
    }
    return decoder
}

// MARK: - Fetcher

/// Actor that fetches remote Claude Code sessions from claude.ai's internal
/// API using cookies from a `ClaudeCookieSource`. On success, flattened rows
/// are persisted via `SeshctlDatabase.upsertRemoteClaudeCodeSessions` and also
/// returned to the caller.
public actor RemoteClaudeCodeFetcher {
    private let cookieSource: ClaudeCookieSource
    private let urlSession: URLSession
    private let database: SeshctlDatabase

    public init(
        cookieSource: ClaudeCookieSource,
        urlSession: URLSession = .shared,
        database: SeshctlDatabase
    ) {
        self.cookieSource = cookieSource
        self.urlSession = urlSession
        self.database = database
    }

    /// Safari UA string. claude.ai's backend appears to gate on UA; a Safari
    /// string sidesteps the gate and also prevents Google OAuth's embedded-view
    /// heuristic (though Google OAuth is out of scope for the fetcher itself).
    public static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"

    /// Fetch and persist the current cloud session list.
    ///
    /// Behavior on failure:
    /// - Missing cookies → `.notConnected` (DB untouched).
    /// - 401 → `.needsReauth` (DB untouched; cached rows stay visible).
    /// - Non-200/401 HTTP → `.http(status)`.
    /// - Transport failure → `.transport(description)`.
    /// - Decode failure → `.decode(description)`.
    @discardableResult
    public func refresh() async throws -> [RemoteClaudeCodeSession] {
        // 1. Pull cookies. Require both sessionKey (HttpOnly) and sessionKeyLC
        //    (non-HttpOnly) scoped to claude.ai. Either missing → not connected.
        let allCookies = await cookieSource.currentCookies()
        let claudeCookies = allCookies.filter { cookie in
            cookie.domain.hasSuffix("claude.ai")
        }
        let hasSessionKey = claudeCookies.contains(where: { $0.name == "sessionKey" })
        let hasSessionKeyLC = claudeCookies.contains(where: { $0.name == "sessionKeyLC" })
        guard hasSessionKey, hasSessionKeyLC else {
            throw RemoteClaudeCodeError.notConnected
        }

        // 2. Build Cookie header from every .claude.ai-domain cookie. The
        //    spike confirmed the server requires the full cookie set — sending
        //    only `sessionKey` returns 401.
        let cookieHeader = claudeCookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        // 3. Build the request with all required headers.
        let request = buildRemoteClaudeCodeRequest(cookieHeader: cookieHeader)

        // 4. Issue the request.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let urlError as URLError {
            throw RemoteClaudeCodeError.transport(urlError.localizedDescription)
        } catch {
            throw RemoteClaudeCodeError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RemoteClaudeCodeError.transport("non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw RemoteClaudeCodeError.needsReauth
        default:
            throw RemoteClaudeCodeError.http(http.statusCode)
        }

        // 5. Decode.
        let decoded: APIListResponse
        do {
            decoded = try makeClaudeJSONDecoder().decode(APIListResponse.self, from: data)
        } catch {
            throw RemoteClaudeCodeError.decode(String(describing: error))
        }

        // 6. Flatten. Drop archived sessions — claude.ai hides them from the
        //    Code tab by default, so surfacing them here misleads the user.
        let flat = decoded.data
            .filter { $0.status != "archived" }
            .map(flattenAPISession)

        // Surface any new `worker_status` values we haven't seen before. This
        // is how we'll discover states like pending-action without a live
        // debugger — `log stream --predicate 'subsystem == "app.seshctl"
        // && category == "remote-fetcher"'` will surface unknown values.
        let unknown = Set(flat.map(\.workerStatus)).subtracting(knownWorkerStatuses)
        for status in unknown {
            fetcherLogger.info("unknown remote worker_status: \(status, privacy: .public)")
        }

        // 7. Persist (replace-all semantics).
        try database.upsertRemoteClaudeCodeSessions(flat)

        // 8. Return.
        return flat
    }

    /// Fetch the latest assistant text for a single remote session by issuing
    /// `GET /v1/code/sessions/<id>/events?limit=10` and running the response
    /// body through `RemoteEventsParser.extractLatestAssistantText`.
    ///
    /// Returns:
    /// - The trimmed first non-empty line of the most-recent assistant event's
    ///   first `type == "text"` content block, when one exists.
    /// - `nil` when the session has no assistant events yet, or the latest
    ///   assistant turn was tool-call-only (no text block). This is a valid
    ///   "no recap available" signal — callers should fall through to the
    ///   default preview.
    ///
    /// Throws on failure (not nil):
    /// - `.notConnected` if either `sessionKey` or `sessionKeyLC` cookies are
    ///   missing (matches `refresh()`'s precondition).
    /// - `.needsReauth` on HTTP 401.
    /// - `.http(status)` on any non-200/401 HTTP status.
    /// - `.transport(...)` on URLSession-level failures or non-HTTP responses.
    public func fetchLatestAssistantText(sessionId: String) async throws -> String? {
        // 1. Pull cookies. Same precondition as `refresh()` — we need both
        //    `sessionKey` (HttpOnly) and `sessionKeyLC` scoped to claude.ai.
        let allCookies = await cookieSource.currentCookies()
        let claudeCookies = allCookies.filter { cookie in
            cookie.domain.hasSuffix("claude.ai")
        }
        let hasSessionKey = claudeCookies.contains(where: { $0.name == "sessionKey" })
        let hasSessionKeyLC = claudeCookies.contains(where: { $0.name == "sessionKeyLC" })
        guard hasSessionKey, hasSessionKeyLC else {
            throw RemoteClaudeCodeError.notConnected
        }

        // 2. Build Cookie header from every .claude.ai-domain cookie.
        let cookieHeader = claudeCookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        // 3. Build URL. Session ids are server-issued (`cse_<base32-ish>`) and
        //    URL-path-safe in practice, but we defensively percent-encode via
        //    URLComponents so anything unexpected can't break the URL.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "claude.ai"
        let encodedId = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        components.path = "/v1/code/sessions/\(encodedId)/events"
        components.queryItems = [URLQueryItem(name: "limit", value: "10")]
        guard let url = components.url else {
            throw RemoteClaudeCodeError.transport("failed to build events URL for session \(sessionId)")
        }

        // 4. Build request via the shared header helper.
        let request = buildAuthedRequest(url: url, cookieHeader: cookieHeader)

        // 5. Issue request and map transport errors.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let urlError as URLError {
            throw RemoteClaudeCodeError.transport(urlError.localizedDescription)
        } catch {
            throw RemoteClaudeCodeError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RemoteClaudeCodeError.transport("non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw RemoteClaudeCodeError.needsReauth
        default:
            throw RemoteClaudeCodeError.http(http.statusCode)
        }

        // 6. Hand the body to the parser. The parser tolerates malformed
        //    JSON (returns nil) so we don't classify decode failures here as
        //    errors — a malformed events body is a "no recap available" outcome
        //    that self-heals on the next `last_event_at` advance.
        return RemoteEventsParser.extractLatestAssistantText(eventsResponseData: data)
    }
}
