import Foundation
import Testing
@testable import SeshctlUI

/// Covers `MessageBodyText.isOpenableLinkScheme` — the allowlist that keeps
/// untrusted transcript links from opening local resources or arbitrary app
/// schemes via NSWorkspace.
struct MessageBodyTextLinkSchemeTests {
    @Test("Web and mail schemes are openable")
    func allowsWebAndMailSchemes() {
        #expect(MessageBodyText.isOpenableLinkScheme(URL(string: "https://example.com")!))
        #expect(MessageBodyText.isOpenableLinkScheme(URL(string: "http://example.com")!))
        #expect(MessageBodyText.isOpenableLinkScheme(URL(string: "mailto:a@b.com")!))
    }

    @Test("Scheme matching is case-insensitive")
    func schemeIsCaseInsensitive() {
        #expect(MessageBodyText.isOpenableLinkScheme(URL(string: "HTTPS://example.com")!))
    }

    @Test("Local-resource and custom app schemes are rejected")
    func rejectsNonWebSchemes() {
        #expect(!MessageBodyText.isOpenableLinkScheme(URL(string: "file:///etc/passwd")!))
        #expect(!MessageBodyText.isOpenableLinkScheme(URL(string: "x-custom-app://do-something")!))
        #expect(!MessageBodyText.isOpenableLinkScheme(URL(string: "javascript:alert(1)")!))
    }

    @Test("A schemeless URL is rejected")
    func rejectsSchemelessURL() {
        #expect(!MessageBodyText.isOpenableLinkScheme(URL(string: "example.com/path")!))
    }
}
