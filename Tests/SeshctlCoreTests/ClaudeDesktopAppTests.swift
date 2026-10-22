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
}
