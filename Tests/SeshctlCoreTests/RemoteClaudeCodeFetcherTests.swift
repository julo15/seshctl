import Foundation
import Testing

@testable import SeshctlCore

// MARK: - Mock URLProtocol

/// Stubs URLSession responses so the fetcher can be tested without real HTTP.
/// The handler receives the outgoing `URLRequest` (so tests can inspect
/// headers) and returns the response + body to deliver.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Actor-isolated capture slot for the most recent request observed by
/// `MockURLProtocol`, so tests can read it after the async fetch completes.
actor RequestCapture {
    private(set) var last: URLRequest?
    func set(_ request: URLRequest) { last = request }
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeCookie(
    name: String,
    value: String = "v",
    domain: String = ".claude.ai"
) -> HTTPCookie {
    HTTPCookie(properties: [
        .domain: domain,
        .path: "/",
        .name: name,
        .value: value,
        .secure: "TRUE",
    ])!
}

private func source(_ cookies: [HTTPCookie]) -> ClosureCookieSource {
    ClosureCookieSource { cookies }
}

private func httpResponse(
    status: Int,
    url: URL = URL(string: "https://claude.ai/v1/code/sessions?limit=50")!
) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

/// Minimal fixture that exercises every field the fetcher cares about.
private let fixtureBothSessions: String = """
{
  "data": [
    {
      "id": "cse_TESTONLY_12345",
      "title": "Investigate cron error rate check alert",
      "status": "active",
      "worker_status": "idle",
      "connection_status": "connected",
      "created_at": "2026-04-15T01:40:25.669139Z",
      "last_event_at": "2026-04-20T17:47:19.514469Z",
      "unread": false,
      "config": {
        "model": "claude-opus-4-6[1m]",
        "sources": [
          {
            "type": "git_repository",
            "url": "https://github.com/julo15/qbk-scheduler",
            "revision": "main",
            "allow_unrestricted_git_push": true,
            "sparse_checkout_paths": []
          }
        ],
        "outcomes": [
          {
            "type": "git_repository",
            "git_info": {
              "type": "github",
              "repo": "julo15/qbk-scheduler",
              "branches": ["main"]
            }
          }
        ]
      }
    },
    {
      "id": "cse_TESTONLY_67890",
      "title": "Second session",
      "status": "active",
      "worker_status": "running",
      "connection_status": "connected",
      "created_at": "2026-04-16T12:00:00.000000Z",
      "last_event_at": "2026-04-20T18:00:00.000000Z",
      "unread": true,
      "config": {
        "model": "claude-opus-4-6[1m]",
        "sources": [
          {
            "type": "git_repository",
            "url": "https://github.com/julo15/other-repo"
          }
        ],
        "outcomes": [
          {
            "type": "git_repository",
            "git_info": {
              "type": "github",
              "repo": "julo15/other-repo",
              "branches": ["dev"]
            }
          }
        ]
      }
    }
  ],
  "next_cursor": null
}
"""

@Suite("RemoteClaudeCodeFetcher", .serialized)
struct RemoteClaudeCodeFetcherTests {

    // MARK: notConnected

    @Test("not connected throws when no cookies")
    func notConnectedWhenNoCookies() async throws {
        let db = try SeshctlDatabase.temporary()
        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([]),
            urlSession: stubbedSession(),
            database: db
        )

        await #expect(throws: RemoteClaudeCodeError.notConnected) {
            try await fetcher.refresh()
        }
    }

    @Test("not connected throws when only sessionKey present")
    func notConnectedWhenOnlySessionKey() async throws {
        let db = try SeshctlDatabase.temporary()
        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([makeCookie(name: "sessionKey")]),
            urlSession: stubbedSession(),
            database: db
        )

        await #expect(throws: RemoteClaudeCodeError.notConnected) {
            try await fetcher.refresh()
        }
    }

    @Test("not connected throws when only sessionKeyLC present")
    func notConnectedWhenOnlySessionKeyLC() async throws {
        let db = try SeshctlDatabase.temporary()
        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([makeCookie(name: "sessionKeyLC")]),
            urlSession: stubbedSession(),
            database: db
        )

        await #expect(throws: RemoteClaudeCodeError.notConnected) {
            try await fetcher.refresh()
        }
    }

    // MARK: success path

    @Test("successful refresh parses and persists")
    func successfulRefreshParsesAndPersists() async throws {
        let db = try SeshctlDatabase.temporary()
        let data = Data(fixtureBothSessions.utf8)
        MockURLProtocol.handler = { _ in (httpResponse(status: 200), data) }
        defer { MockURLProtocol.handler = nil }

        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([
                makeCookie(name: "sessionKey"),
                makeCookie(name: "sessionKeyLC"),
            ]),
            urlSession: stubbedSession(),
            database: db
        )

        let result = try await fetcher.refresh()
        #expect(result.count == 2)

        let first = result[0]
        #expect(first.id == "cse_TESTONLY_12345")
        #expect(first.title == "Investigate cron error rate check alert")
        #expect(first.branches == ["main"])
        #expect(first.repoUrl == "https://github.com/julo15/qbk-scheduler")

        let listed = try db.listRemoteClaudeCodeSessions()
        #expect(listed.count == 2)
    }

    // MARK: error paths

    @Test("401 throws needsReauth and leaves DB untouched")
    func unauthorizedLeavesDBUntouched() async throws {
        let db = try SeshctlDatabase.temporary()

        // Seed DB with one session.
        let seeded = RemoteClaudeCodeSession(
            id: "cse_SEEDED",
            title: "Seeded",
            model: "claude-opus-4-6[1m]",
            repoUrl: "https://github.com/julo15/qbk-scheduler",
            branches: ["main"],
            status: "active",
            workerStatus: "idle",
            connectionStatus: "connected",
            lastEventAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            unread: false
        )
        try db.upsertRemoteClaudeCodeSessions([seeded])
        #expect(try db.listRemoteClaudeCodeSessions().count == 1)

        MockURLProtocol.handler = { _ in (httpResponse(status: 401), Data()) }
        defer { MockURLProtocol.handler = nil }

        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([
                makeCookie(name: "sessionKey"),
                makeCookie(name: "sessionKeyLC"),
            ]),
            urlSession: stubbedSession(),
            database: db
        )

        await #expect(throws: RemoteClaudeCodeError.needsReauth) {
            try await fetcher.refresh()
        }

        // DB still has the seeded row.
        let listed = try db.listRemoteClaudeCodeSessions()
        #expect(listed.count == 1)
        #expect(listed[0].id == "cse_SEEDED")
    }

    @Test("500 throws http 500")
    func serverErrorThrowsHTTP() async throws {
        let db = try SeshctlDatabase.temporary()
        MockURLProtocol.handler = { _ in (httpResponse(status: 500), Data()) }
        defer { MockURLProtocol.handler = nil }

        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([
                makeCookie(name: "sessionKey"),
                makeCookie(name: "sessionKeyLC"),
            ]),
            urlSession: stubbedSession(),
            database: db
        )

        await #expect(throws: RemoteClaudeCodeError.http(500)) {
            try await fetcher.refresh()
        }
    }

    @Test("malformed JSON throws decode")
    func malformedJSONThrowsDecode() async throws {
        let db = try SeshctlDatabase.temporary()
        MockURLProtocol.handler = { _ in
            (httpResponse(status: 200), Data("not json at all".utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([
                makeCookie(name: "sessionKey"),
                makeCookie(name: "sessionKeyLC"),
            ]),
            urlSession: stubbedSession(),
            database: db
        )

        do {
            _ = try await fetcher.refresh()
            Issue.record("Expected decode error but refresh succeeded")
        } catch let error as RemoteClaudeCodeError {
            if case .decode = error {
                // expected
            } else {
                Issue.record("Expected .decode, got \(error)")
            }
        }
    }

    // MARK: headers

    @Test("request has required headers")
    func requestHasRequiredHeaders() async throws {
        let db = try SeshctlDatabase.temporary()
        let capture = RequestCapture()
        let data = Data(fixtureBothSessions.utf8)

        MockURLProtocol.handler = { request in
            // Fire-and-forget capture — tests await it below.
            Task { await capture.set(request) }
            return (httpResponse(status: 200), data)
        }
        defer { MockURLProtocol.handler = nil }

        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([
                makeCookie(name: "sessionKey", value: "SK_VAL"),
                makeCookie(name: "sessionKeyLC", value: "SKLC_VAL"),
                makeCookie(name: "lastActiveOrg", value: "ORG_VAL"),
            ]),
            urlSession: stubbedSession(),
            database: db
        )

        _ = try await fetcher.refresh()

        // Give the capture Task a moment to land. We just await on the actor.
        let last = await capture.last
        let req = try #require(last)

        #expect(req.url?.absoluteString == "https://claude.ai/v1/code/sessions?limit=50")

        let cookie = try #require(req.value(forHTTPHeaderField: "Cookie"))
        #expect(cookie.contains("sessionKey=SK_VAL"))
        #expect(cookie.contains("sessionKeyLC=SKLC_VAL"))

        #expect(req.value(forHTTPHeaderField: "Origin") == "https://claude.ai")
        #expect(req.value(forHTTPHeaderField: "Referer") == "https://claude.ai/code")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == RemoteClaudeCodeFetcher.safariUserAgent)
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "managed-agents-2026-04-01")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    // MARK: branch / repo extraction

    @Test("branches extraction")
    func branchesExtraction() async throws {
        let db = try SeshctlDatabase.temporary()
        let fixture = """
        {
          "data": [
            {
              "id": "cse_TESTONLY_branches",
              "title": "Has branches",
              "status": "active",
              "worker_status": "idle",
              "connection_status": "connected",
              "created_at": "2026-04-15T01:40:25.669139Z",
              "last_event_at": "2026-04-20T17:47:19.514469Z",
              "unread": false,
              "config": {
                "model": "claude-opus-4-6[1m]",
                "sources": [
                  {
                    "type": "git_repository",
                    "url": "https://github.com/julo15/qbk-scheduler"
                  }
                ],
                "outcomes": [
                  {
                    "type": "git_repository",
                    "git_info": {
                      "type": "github",
                      "repo": "julo15/qbk-scheduler",
                      "branches": ["main", "dev"]
                    }
                  }
                ]
              }
            }
          ],
          "next_cursor": null
        }
        """
        MockURLProtocol.handler = { _ in (httpResponse(status: 200), Data(fixture.utf8)) }
        defer { MockURLProtocol.handler = nil }

        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([
                makeCookie(name: "sessionKey"),
                makeCookie(name: "sessionKeyLC"),
            ]),
            urlSession: stubbedSession(),
            database: db
        )

        let result = try await fetcher.refresh()
        #expect(result.count == 1)
        #expect(result[0].branches == ["main", "dev"])
    }

    @Test("outcomes missing defaults to empty branches")
    func missingOutcomesEmptyBranches() async throws {
        let db = try SeshctlDatabase.temporary()
        let fixture = """
        {
          "data": [
            {
              "id": "cse_TESTONLY_no_outcomes",
              "title": "No outcomes",
              "status": "active",
              "worker_status": "idle",
              "connection_status": "connected",
              "created_at": "2026-04-15T01:40:25.669139Z",
              "last_event_at": "2026-04-20T17:47:19.514469Z",
              "unread": false,
              "config": {
                "model": "claude-opus-4-6[1m]",
                "sources": [
                  {
                    "type": "git_repository",
                    "url": "https://github.com/julo15/qbk-scheduler"
                  }
                ]
              }
            }
          ],
          "next_cursor": null
        }
        """
        MockURLProtocol.handler = { _ in (httpResponse(status: 200), Data(fixture.utf8)) }
        defer { MockURLProtocol.handler = nil }

        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([
                makeCookie(name: "sessionKey"),
                makeCookie(name: "sessionKeyLC"),
            ]),
            urlSession: stubbedSession(),
            database: db
        )

        let result = try await fetcher.refresh()
        #expect(result.count == 1)
        #expect(result[0].branches == [])
    }

    @Test("repoUrl picks first git_repository source")
    func repoUrlPicksFirstGitRepository() async throws {
        let db = try SeshctlDatabase.temporary()
        let fixture = """
        {
          "data": [
            {
              "id": "cse_TESTONLY_mixed_sources",
              "title": "Mixed sources",
              "status": "active",
              "worker_status": "idle",
              "connection_status": "connected",
              "created_at": "2026-04-15T01:40:25.669139Z",
              "last_event_at": "2026-04-20T17:47:19.514469Z",
              "unread": false,
              "config": {
                "model": "claude-opus-4-6[1m]",
                "sources": [
                  {
                    "type": "other_source",
                    "url": "https://example.com/not-a-repo"
                  },
                  {
                    "type": "git_repository",
                    "url": "https://github.com/julo15/the-repo"
                  },
                  {
                    "type": "git_repository",
                    "url": "https://github.com/julo15/second-repo"
                  }
                ]
              }
            }
          ],
          "next_cursor": null
        }
        """
        MockURLProtocol.handler = { _ in (httpResponse(status: 200), Data(fixture.utf8)) }
        defer { MockURLProtocol.handler = nil }

        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([
                makeCookie(name: "sessionKey"),
                makeCookie(name: "sessionKeyLC"),
            ]),
            urlSession: stubbedSession(),
            database: db
        )

        let result = try await fetcher.refresh()
        #expect(result.count == 1)
        #expect(result[0].repoUrl == "https://github.com/julo15/the-repo")
    }

    // MARK: - fetchLatestAssistantText
    //
    // These tests live inside the same `.serialized` `RemoteClaudeCodeFetcher`
    // suite as `refresh()`'s tests because both groups share the process-wide
    // `MockURLProtocol.handler` static. Cross-suite parallelism otherwise
    // clobbers the handler between concurrent tests.

    @Test("fetchLatestAssistantText: missing sessionKey throws notConnected")
    func fetchEventsMissingSessionKeyThrowsNotConnected() async throws {
        let db = try SeshctlDatabase.temporary()
        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([makeCookie(name: "sessionKeyLC")]),
            urlSession: stubbedSession(),
            database: db
        )

        await #expect(throws: RemoteClaudeCodeError.notConnected) {
            try await fetcher.fetchLatestAssistantText(sessionId: "cse_test_123")
        }
    }

    @Test("fetchLatestAssistantText: missing sessionKeyLC throws notConnected")
    func fetchEventsMissingSessionKeyLCThrowsNotConnected() async throws {
        let db = try SeshctlDatabase.temporary()
        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([makeCookie(name: "sessionKey")]),
            urlSession: stubbedSession(),
            database: db
        )

        await #expect(throws: RemoteClaudeCodeError.notConnected) {
            try await fetcher.fetchLatestAssistantText(sessionId: "cse_test_123")
        }
    }

    @Test("fetchLatestAssistantText: request URL and headers are canonical")
    func fetchEventsRequestURLAndHeadersAreCanonical() async throws {
        let db = try SeshctlDatabase.temporary()
        let capture = RequestCapture()
        let data = Data(fixtureSimpleAssistantEvents.utf8)

        MockURLProtocol.handler = { request in
            Task { await capture.set(request) }
            let url = request.url ?? URL(string: "https://claude.ai/v1/code/sessions/cse_test_123/events?limit=10")!
            return (httpResponse(status: 200, url: url), data)
        }
        defer { MockURLProtocol.handler = nil }

        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([
                makeCookie(name: "sessionKey", value: "SK_VAL"),
                makeCookie(name: "sessionKeyLC", value: "SKLC_VAL"),
            ]),
            urlSession: stubbedSession(),
            database: db
        )

        _ = try await fetcher.fetchLatestAssistantText(sessionId: "cse_test_123")

        let last = await capture.last
        let req = try #require(last)

        #expect(req.url?.absoluteString == "https://claude.ai/v1/code/sessions/cse_test_123/events?limit=10")
        #expect(req.httpMethod == "GET")

        let cookie = try #require(req.value(forHTTPHeaderField: "Cookie"))
        #expect(cookie.contains("sessionKey=SK_VAL"))
        #expect(cookie.contains("sessionKeyLC=SKLC_VAL"))

        #expect(req.value(forHTTPHeaderField: "Origin") == "https://claude.ai")
        #expect(req.value(forHTTPHeaderField: "Referer") == "https://claude.ai/code")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == RemoteClaudeCodeFetcher.safariUserAgent)
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "managed-agents-2026-04-01")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("fetchLatestAssistantText: returns parsed assistant text on 200")
    func fetchEventsReturnsParsedAssistantTextOn200() async throws {
        let db = try SeshctlDatabase.temporary()
        let data = Data(fixtureSimpleAssistantEvents.utf8)
        MockURLProtocol.handler = { request in
            let url = request.url ?? URL(string: "https://claude.ai/v1/code/sessions/cse_test_123/events?limit=10")!
            return (httpResponse(status: 200, url: url), data)
        }
        defer { MockURLProtocol.handler = nil }

        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([
                makeCookie(name: "sessionKey"),
                makeCookie(name: "sessionKeyLC"),
            ]),
            urlSession: stubbedSession(),
            database: db
        )

        let result = try await fetcher.fetchLatestAssistantText(sessionId: "cse_test_123")
        #expect(result == "Pushed.")
    }

    @Test("fetchLatestAssistantText: returns nil when parser finds no assistant text")
    func fetchEventsReturnsNilWhenParserFindsNoAssistantText() async throws {
        let db = try SeshctlDatabase.temporary()
        let data = Data(fixtureNoAssistantEvents.utf8)
        MockURLProtocol.handler = { request in
            let url = request.url ?? URL(string: "https://claude.ai/v1/code/sessions/cse_test_123/events?limit=10")!
            return (httpResponse(status: 200, url: url), data)
        }
        defer { MockURLProtocol.handler = nil }

        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([
                makeCookie(name: "sessionKey"),
                makeCookie(name: "sessionKeyLC"),
            ]),
            urlSession: stubbedSession(),
            database: db
        )

        let result = try await fetcher.fetchLatestAssistantText(sessionId: "cse_test_123")
        #expect(result == nil)
    }

    @Test("fetchLatestAssistantText: 401 throws needsReauth")
    func fetchEventsUnauthorizedThrowsNeedsReauth() async throws {
        let db = try SeshctlDatabase.temporary()
        MockURLProtocol.handler = { request in
            let url = request.url ?? URL(string: "https://claude.ai/v1/code/sessions/cse_test_123/events?limit=10")!
            return (httpResponse(status: 401, url: url), Data())
        }
        defer { MockURLProtocol.handler = nil }

        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([
                makeCookie(name: "sessionKey"),
                makeCookie(name: "sessionKeyLC"),
            ]),
            urlSession: stubbedSession(),
            database: db
        )

        await #expect(throws: RemoteClaudeCodeError.needsReauth) {
            try await fetcher.fetchLatestAssistantText(sessionId: "cse_test_123")
        }
    }

    @Test("fetchLatestAssistantText: 500 throws http 500")
    func fetchEventsServerErrorThrowsHTTP() async throws {
        let db = try SeshctlDatabase.temporary()
        MockURLProtocol.handler = { request in
            let url = request.url ?? URL(string: "https://claude.ai/v1/code/sessions/cse_test_123/events?limit=10")!
            return (httpResponse(status: 500, url: url), Data())
        }
        defer { MockURLProtocol.handler = nil }

        let fetcher = RemoteClaudeCodeFetcher(
            cookieSource: source([
                makeCookie(name: "sessionKey"),
                makeCookie(name: "sessionKeyLC"),
            ]),
            urlSession: stubbedSession(),
            database: db
        )

        await #expect(throws: RemoteClaudeCodeError.http(500)) {
            try await fetcher.fetchLatestAssistantText(sessionId: "cse_test_123")
        }
    }
}

// MARK: - events fixtures

/// Minimal events-endpoint response with one assistant event whose first text
/// block is "Pushed.".
private let fixtureSimpleAssistantEvents: String = """
{
  "data": [
    {
      "event_type": "assistant",
      "payload": {
        "message": {
          "content": [
            { "type": "text", "text": "Pushed." }
          ]
        }
      }
    }
  ],
  "next_cursor": null
}
"""

/// Events response with no assistant events (only `result`-type entries).
private let fixtureNoAssistantEvents: String = """
{
  "data": [
    {
      "event_type": "result",
      "payload": {}
    }
  ],
  "next_cursor": null
}
"""
