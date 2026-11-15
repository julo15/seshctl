import Foundation
import Testing
@testable import SeshctlCore

@Suite("ClaudeDesktopApp")
struct ClaudeDesktopAppTests {
    // MARK: - Registry constants

    @Test("registry exposes the desktop app's bundle ID and URL scheme")
    func registryConstants() {
        #expect(ClaudeDesktopApp.bundleId == "com.anthropic.claudefordesktop")
        #expect(ClaudeDesktopApp.scheme == "claude")
    }

    // MARK: - sessionURL(for:)

    @Test("cse_ id builds claude://code/<id>")
    func cseIdBuildsDeepLink() {
        let url = ClaudeDesktopApp.sessionURL(for: "cse_01F8NDyxDuhrnWdEdpvBzSsG")
        #expect(url?.absoluteString == "claude://code/cse_01F8NDyxDuhrnWdEdpvBzSsG")
    }

    @Test("session_ id builds claude://code/<id>")
    func sessionIdBuildsDeepLink() {
        let url = ClaudeDesktopApp.sessionURL(for: "session_01F8NDyxDuhrnWdEdpvBzSsG")
        #expect(url?.absoluteString == "claude://code/session_01F8NDyxDuhrnWdEdpvBzSsG")
    }

    @Test("ids with underscores and hyphens in the suffix are accepted")
    func suffixAllowsUnderscoreAndHyphen() {
        #expect(ClaudeDesktopApp.sessionURL(for: "cse_a-b_c")?.absoluteString == "claude://code/cse_a-b_c")
        #expect(ClaudeDesktopApp.isValidSessionId("cse_a-b_c"))
    }

    @Test(
        "invalid or injection-shaped ids return nil",
        arguments: [
            "",
            "cse_",
            "session_",
            "cse",
            "abc123",
            "chat_abc",
            "CSE_abc",
            "xcse_abc",
            "cse_a/b",
            "cse_a?x=1",
            "cse_a#frag",
            "cse_a b",
            "cse_a%2Fb",
            "cse_../../etc",
            "cse_abc\n",
            "cse_abc\"",
            "cse_ab\u{00E9}",
            "cse_\u{FF41}bc",
            "session_a:b",
        ]
    )
    func invalidIdsReturnNil(id: String) {
        #expect(ClaudeDesktopApp.sessionURL(for: id) == nil)
        #expect(!ClaudeDesktopApp.isValidSessionId(id))
    }

    // MARK: - sessionURL(fromWebURL:)

    @Test("claude.ai web URL maps to the desktop deep link")
    func webUrlMapsToDeepLink() {
        let web = URL(string: "https://claude.ai/code/session_01F8NDyxDuhrnWdEdpvBzSsG")!
        #expect(
            ClaudeDesktopApp.sessionURL(fromWebURL: web)?.absoluteString
                == "claude://code/session_01F8NDyxDuhrnWdEdpvBzSsG"
        )
    }

    @Test(
        "non-session web URLs return nil",
        arguments: [
            "https://claude.ai/code/session_abc/extra",
            "https://claude.ai/code/",
            "https://claude.ai/code",
            "https://claude.ai/chat/session_abc",
            "https://evil.example/code/session_abc",
            "http://claude.ai/code/session_abc",
            "https://claude.ai/code/session_a%20b",
            "https://claude.ai/code/session_a%2Fb",
            "https://claude.ai/code/notasession",
        ]
    )
    func nonSessionWebUrlsReturnNil(raw: String) {
        let web = URL(string: raw)!
        #expect(ClaudeDesktopApp.sessionURL(fromWebURL: web) == nil)
    }

    // MARK: - Local sessions

    @Test("valid local_ ids pass and build claude://code/continue")
    func localIdBuildsContinueURL() {
        let id = "local_e5a16719-c99a-42de-b094-e0aa9d3217bb"
        #expect(ClaudeDesktopApp.isValidLocalSessionId(id))
        #expect(ClaudeDesktopApp.continueURL(localSessionId: id)?.absoluteString
            == "claude://code/continue?session=local_e5a16719-c99a-42de-b094-e0aa9d3217bb")
    }

    @Test(
        "invalid local ids are rejected",
        arguments: [
            "",
            "local_",
            "cse_abc",
            "local_abc_def",
            "local_abc&session=x",
            "local_abc def",
            "local_" + String(repeating: "a", count: 65),
        ]
    )
    func invalidLocalIds(id: String) {
        #expect(!ClaudeDesktopApp.isValidLocalSessionId(id))
        #expect(ClaudeDesktopApp.continueURL(localSessionId: id) == nil)
    }

    @Test("a 64-character local suffix is accepted")
    func localIdMaxLength() {
        #expect(ClaudeDesktopApp.isValidLocalSessionId("local_" + String(repeating: "a", count: 64)))
    }

    /// Writes `<root>/acct/org/<name>` with the given JSON object.
    static func writeSessionFile(root: URL, name: String, json: [String: Any]) throws {
        let dir = root.appendingPathComponent("acct/org", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: dir.appendingPathComponent(name))
    }

    static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-desktop-sessions-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("localSessionId finds the file whose cliSessionId matches")
    func resolvesByCliSessionId() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSessionFile(root: root, name: "local_aaa.json", json: ["sessionId": "local_aaa", "cliSessionId": "conv-1"])
        try Self.writeSessionFile(root: root, name: "local_bbb.json", json: ["sessionId": "local_bbb", "cliSessionId": "conv-2"])

        #expect(ClaudeDesktopApp.localSessionId(forCliSessionId: "conv-2", sessionsRoot: root) == "local_bbb")
        #expect(ClaudeDesktopApp.localSessionId(forCliSessionId: "conv-3", sessionsRoot: root) == nil)
    }

    @Test("localSessionId also matches lastAssistantCliSessionId")
    func resolvesByLastAssistantCliSessionId() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSessionFile(root: root, name: "local_aaa.json", json: [
            "sessionId": "local_aaa", "cliSessionId": "conv-old", "lastAssistantCliSessionId": "conv-new",
        ])

        #expect(ClaudeDesktopApp.localSessionId(forCliSessionId: "conv-new", sessionsRoot: root) == "local_aaa")
    }

    @Test("localSessionId skips archived sessions, non-session files and invalid ids")
    func skipsArchivedAndInvalid() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSessionFile(root: root, name: "local_arch.json", json: ["sessionId": "local_arch", "cliSessionId": "conv-1", "isArchived": true])
        try Self.writeSessionFile(root: root, name: "scheduled-tasks.json", json: ["sessionId": "local_x", "cliSessionId": "conv-2"])
        try Self.writeSessionFile(root: root, name: "local_bad.json", json: ["sessionId": "local_bad&x=1", "cliSessionId": "conv-3"])
        // The id appears in the file, but not as the CLI session id.
        try Self.writeSessionFile(root: root, name: "local_other.json", json: ["sessionId": "local_other", "cliSessionId": "conv-9", "note": "conv-4"])

        for conv in ["conv-1", "conv-2", "conv-3", "conv-4", ""] {
            #expect(ClaudeDesktopApp.localSessionId(forCliSessionId: conv, sessionsRoot: root) == nil)
        }
    }

    @Test("localSessionId returns nil when the sessions folder doesn't exist")
    func missingRoot() {
        #expect(ClaudeDesktopApp.localSessionId(forCliSessionId: "conv-1", sessionsRoot: Self.makeRoot()) == nil)
    }
}
