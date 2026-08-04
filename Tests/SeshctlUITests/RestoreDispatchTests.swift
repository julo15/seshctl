import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

/// Covers `SessionAction`'s multi-session restore: which sessions make it into
/// the dispatch list, in what order, and how the tabs are spaced.
@Suite("Restore dispatch")
struct RestoreDispatchTests {

    private func makeSession(
        id: String = UUID().uuidString,
        tool: SessionTool = .claude,
        conversationId: String? = "conv-1",
        directory: String = "/tmp",
        launchArgs: String? = nil
    ) -> Session {
        Session(
            id: id,
            conversationId: conversationId,
            tool: tool,
            directory: directory,
            launchDirectory: directory,
            hostWorkspaceFolder: nil,
            lastAsk: nil,
            lastReply: nil,
            status: .stale,
            pid: nil,
            hostAppBundleId: "com.mitchellh.ghostty",
            hostAppName: "Ghostty",
            windowId: nil,
            transcriptPath: nil,
            gitRepoName: nil,
            gitBranch: nil,
            launchArgs: launchArgs,
            startedAt: Date(),
            updatedAt: Date(),
            lastReadAt: nil
        )
    }

    @Test("Every restorable session reaches the dispatch list, in order")
    func plansPreserveOrder() {
        let env = MockSystemEnvironment()
        let sessions = (0..<3).map {
            makeSession(conversationId: "conv-\($0)", directory: "/tmp/\($0)")
        }

        let plans = SessionAction.restorePlans(for: sessions, environment: env)

        #expect(plans.count == 3)
        #expect(plans.map(\SessionAction.RestorePlan.directory) == ["/tmp/0", "/tmp/1", "/tmp/2"])
        #expect(plans[0].command == "claude --resume conv-0")
    }

    @Test("Each tool gets its own resume form")
    func plansUsePerToolResumeCommand() {
        let env = MockSystemEnvironment()
        let sessions = [
            makeSession(tool: .claude, conversationId: "c1"),
            makeSession(tool: .codex, conversationId: "c2"),
            makeSession(tool: .pi, conversationId: "c3"),
        ]

        let commands = SessionAction.restorePlans(for: sessions, environment: env).map(\.command)

        #expect(commands == ["claude --resume c1", "codex resume c2", "pi --session c3"])
    }

    @Test("Sessions with no resume command are dropped from the dispatch list")
    func plansDropUnrestorable() {
        let env = MockSystemEnvironment()
        let sessions = [
            makeSession(tool: .claude, conversationId: "c1"),
            // Cursor has no shell resume CLI.
            makeSession(tool: .cursor, conversationId: "c2"),
            // No conversation id means nothing to resume against.
            makeSession(tool: .claude, conversationId: nil),
        ]

        let plans = SessionAction.restorePlans(for: sessions, environment: env)

        #expect(plans.count == 1)
        #expect(plans[0].command == "claude --resume c1")
    }

    @Test("Plans carry the session's recorded host app")
    func plansResolveHostApp() {
        let env = MockSystemEnvironment()
        let plans = SessionAction.restorePlans(for: [makeSession()], environment: env)

        #expect(plans[0].bundleId == "com.mitchellh.ghostty")
    }

    @Test("An empty input produces an empty dispatch list")
    func plansHandleEmptyInput() {
        let env = MockSystemEnvironment()

        #expect(SessionAction.restorePlans(for: [], environment: env).isEmpty)
    }

    @Test("Restoring one session opens one tab")
    func singleRestoreDispatches() {
        let env = MockSystemEnvironment()
        var dismissed = false

        SessionAction.execute(
            target: .restoreSessions([makeSession()]),
            markRead: { _ in },
            rememberFocused: { _ in },
            dismiss: { dismissed = true },
            environment: env
        )

        #expect(dismissed)
        #expect(env.shellCommands.contains { $0.1.contains("com.mitchellh.ghostty") })
    }

    @Test("Restoring marks every session read and dismisses once")
    func multiRestoreMarksReadAndDismissesOnce() {
        let env = MockSystemEnvironment()
        var readIds: [String] = []
        var dismissCount = 0
        let sessions = (0..<3).map {
            makeSession(id: "s\($0)", conversationId: "conv-\($0)")
        }

        SessionAction.execute(
            target: .restoreSessions(sessions),
            markRead: { readIds.append($0.id) },
            rememberFocused: { _ in },
            dismiss: { dismissCount += 1 },
            environment: env
        )

        #expect(readIds == ["s0", "s1", "s2"])
        // One dismiss for the whole batch. The panel must not fight the tabs
        // it is opening for foreground.
        #expect(dismissCount == 1)
    }

    @Test("The first tab is requested synchronously and the rest are spaced out")
    func multiRestoreStaggers() {
        let env = MockSystemEnvironment()
        let sessions = (0..<3).map {
            makeSession(id: "s\($0)", conversationId: "conv-\($0)")
        }

        SessionAction.execute(
            target: .restoreSessions(sessions),
            markRead: { _ in },
            rememberFocused: { _ in },
            dismiss: {},
            environment: env
        )

        // Only the head of the walk has run. The remaining two are queued
        // behind `restoreStagger`, which is what keeps their AppleScripts from
        // racing for the same front window.
        #expect(env.shellCommands.count == 1)
        #expect(SessionAction.restoreStagger > 0)
    }

    @Test("An empty restore does nothing at all")
    func emptyRestoreIsNoOp() {
        let env = MockSystemEnvironment()
        var dismissed = false

        SessionAction.execute(
            target: .restoreSessions([]),
            markRead: { _ in },
            rememberFocused: { _ in },
            dismiss: { dismissed = true },
            environment: env
        )

        #expect(!dismissed)
        #expect(env.shellCommands.isEmpty)
    }
}
