import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

@Suite("HostAppResolver.resolve")
struct HostAppResolverResolveTests {
    @Test("Uses the host app stored on the session")
    @MainActor
    func usesStoredHostApp() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(
            tool: .claude, directory: "/tmp/a", pid: 4242,
            hostAppBundleId: "com.mitchellh.ghostty", hostAppName: "Ghostty"
        )
        let info = HostAppResolver().resolve(session: session)
        #expect(info.bundleId == "com.mitchellh.ghostty")
        #expect(info.name == "Ghostty")
    }

    @Test("Falls back to the bundle id when no name was stored")
    @MainActor
    func fallsBackToBundleIdName() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(
            tool: .claude, directory: "/tmp/a", pid: 4243,
            hostAppBundleId: "com.example.term"
        )
        #expect(HostAppResolver().resolve(session: session).name == "com.example.term")
    }

    @Test("Resolves to unknown with no stored host app and no pid")
    @MainActor
    func unknownWithoutHostAppOrPid() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(conversationId: "conv-1", tool: .cursor, directory: "/tmp/a")
        #expect(session.pid == nil)
        let info = HostAppResolver().resolve(session: session)
        #expect(info.bundleId == HostAppInfo.unknown.bundleId)
        #expect(info.name == "Unknown")
    }

    @Test("Caches per session id")
    @MainActor
    func cachesPerSession() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(
            tool: .claude, directory: "/tmp/a", pid: 4244,
            hostAppBundleId: "com.mitchellh.ghostty", hostAppName: "Ghostty"
        )
        let resolver = HostAppResolver()
        let first = resolver.resolve(session: session)
        let second = resolver.resolve(session: session)
        #expect(first.icon === second.icon)
    }
}

@Suite("HostAppResolver.claudeDesktopApp")
struct HostAppResolverClaudeDesktopTests {
    @Test("Returns nil when the Claude desktop app isn't installed")
    @MainActor
    func nilWhenNotInstalled() {
        let env = MockSystemEnvironment()
        let resolver = HostAppResolver()
        #expect(resolver.claudeDesktopApp(environment: env) == nil)
    }

    @Test("Returns the Claude desktop app's info when installed")
    @MainActor
    func infoWhenInstalled() throws {
        let env = MockSystemEnvironment()
        env.appBundleURLs[ClaudeDesktopApp.bundleId] = URL(fileURLWithPath: "/Applications/Claude.app")
        let resolver = HostAppResolver()

        let info = try #require(resolver.claudeDesktopApp(environment: env))
        #expect(info.bundleId == ClaudeDesktopApp.bundleId)
        #expect(info.name == "Claude")
    }

    @Test("Caches the first lookup")
    @MainActor
    func cachesLookup() {
        let env = MockSystemEnvironment()
        env.appBundleURLs[ClaudeDesktopApp.bundleId] = URL(fileURLWithPath: "/Applications/Claude.app")
        let resolver = HostAppResolver()
        #expect(resolver.claudeDesktopApp(environment: env) != nil)

        env.appBundleURLs = [:]
        #expect(resolver.claudeDesktopApp(environment: env) != nil)
    }
}
