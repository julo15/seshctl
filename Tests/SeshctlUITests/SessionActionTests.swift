import AppKit
import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

private func makeSession(
    id: String = UUID().uuidString,
    tool: SessionTool = .claude,
    conversationId: String? = "abc-123",
    directory: String = "/tmp",
    launchDirectory: String? = nil,
    hostWorkspaceFolder: String? = nil,
    status: SessionStatus = .idle,
    pid: Int? = 12345,
    hostAppBundleId: String? = nil,
    windowId: String? = nil,
    launchArgs: String? = nil
) -> Session {
    Session(
        id: id,
        conversationId: conversationId,
        tool: tool,
        directory: directory,
        launchDirectory: launchDirectory,
        hostWorkspaceFolder: hostWorkspaceFolder,
        lastAsk: nil,
        lastReply: nil,
        status: status,
        pid: pid,
        hostAppBundleId: hostAppBundleId,
        hostAppName: nil,
        windowId: windowId,
        transcriptPath: nil,
        gitRepoName: nil,
        gitBranch: nil,
        launchArgs: launchArgs,
        startedAt: Date(),
        updatedAt: Date(),
        lastReadAt: nil
    )
}

private func makeCallbacks() -> (
    markRead: (Session) -> Void,
    rememberFocused: (Session) -> Void,
    dismiss: () -> Void,
    markedRead: () -> [String],
    remembered: () -> [String],
    dismissed: () -> Int
) {
    var markedReadIds: [String] = []
    var rememberedIds: [String] = []
    var dismissCount = 0
    return (
        markRead: { markedReadIds.append($0.id) },
        rememberFocused: { rememberedIds.append($0.id) },
        dismiss: { dismissCount += 1 },
        markedRead: { markedReadIds },
        remembered: { rememberedIds },
        dismissed: { dismissCount }
    )
}

@Suite("SessionAction", .serialized)
struct SessionActionTests {

    init() {
        // Same rationale as ForkRoutingTests.init — fork dispatch is async in
        // production; override to sync so post-call assertions are deterministic.
        // Re-asserting here (Swift Testing re-instantiates the suite per test)
        // means we don't rely on whatever previous suite happened to leave the
        // executor in.
        TerminalController.forkExecutor = { $0() }
    }

    @Test("Active session marks read, remembers, and dismisses")
    func activeSessionMarksReadRemembersDismisses() {
        let session = makeSession(status: .idle, pid: 12345)
        let env = MockSystemEnvironment()
        env.guiApps = [12345: "com.apple.Terminal"]
        env.ttys = [12345: "/dev/ttys042"]
        let cb = makeCallbacks()
        SessionAction.execute(
            target: .activeSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.markedRead() == [session.id])
        #expect(cb.remembered() == [session.id])
        #expect(cb.dismissed() == 1)
    }

    @Test("Active VS Code session with hostWorkspaceFolder drives focus with that value")
    func activeVSCodeSessionUsesHostWorkspaceFolder() {
        let session = makeSession(
            directory: "/tmp/worktree",
            launchDirectory: "/tmp/launch",
            hostWorkspaceFolder: "/tmp/host-workspace",
            status: .idle,
            pid: 300,
            hostAppBundleId: "com.microsoft.VSCode"
        )
        let env = MockSystemEnvironment()
        env.guiApps = [300: "com.microsoft.VSCode"]

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .activeSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        // open -b should be called with the hostWorkspaceFolder
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.microsoft.VSCode", "/tmp/host-workspace"] })
        #expect(!env.shellCommands.contains { $0.1.contains("/tmp/launch") })
        #expect(!env.shellCommands.contains { $0.1.contains("/tmp/worktree") })
    }

    @Test("Active Cursor chat session with nil PID still focuses via /focus-chat URI")
    func activeCursorSessionWithNilPidStillFocuses() {
        // Cursor rows can have pid: nil when the row was lazy-created on an
        // update event (not via sessionStart). Focus must still dispatch
        // because composer.openComposer keys on conversationId, not pid.
        let session = makeSession(
            tool: .cursor,
            conversationId: "71836c6c-58b9-4081-bd3e-b6a953b2378c",
            directory: "/Users/julianlo/Documents/me/seshctl",
            status: .idle,
            pid: nil,
            hostAppBundleId: "com.todesktop.230313mzl4w4u92"
        )
        let env = MockSystemEnvironment()

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .activeSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.dismissed() == 1)
        #expect(cb.markedRead() == [session.id])
        // Leg 1: open -b on the Cursor workspace
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.todesktop.230313mzl4w4u92", "/Users/julianlo/Documents/me/seshctl"] })
        // Leg 2: focus-chat URI with the conversationId
        #expect(env.shellCommands.contains { $0.1.first?.contains("/focus-chat?id=71836c6c-58b9-4081-bd3e-b6a953b2378c") == true })
        // Must NOT use the terminal-focus URI
        #expect(!env.shellCommands.contains { $0.1.first?.contains("/focus-terminal") == true })
    }

    @Test("Completed Cursor chat session with nil PID falls through to focus")
    func completedCursorSessionWithNilPidFallsToFocus() {
        // Completed Cursor rows (sessionEnd fired) also have pid: nil when
        // lazy-created. buildResumeCommand returns nil for .cursor, so the
        // resume path falls through to focusActiveSession — which must
        // recognize Cursor + conversationId even without a pid.
        let session = makeSession(
            tool: .cursor,
            conversationId: "71836c6c-58b9-4081-bd3e-b6a953b2378c",
            directory: "/Users/julianlo/Documents/me/seshctl",
            status: .completed,
            pid: nil,
            hostAppBundleId: "com.todesktop.230313mzl4w4u92"
        )
        let env = MockSystemEnvironment()

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .inactiveSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.markedRead() == [session.id])
        #expect(env.shellCommands.contains { $0.1.first?.contains("/focus-chat?id=71836c6c-58b9-4081-bd3e-b6a953b2378c") == true })
    }

    @Test("Inactive session with conversationId resumes and dismisses")
    func inactiveSessionWithConversationIdResumes() {
        let session = makeSession(
            conversationId: "abc-123",
            directory: "/tmp",
            status: .completed,
            hostAppBundleId: "com.apple.Terminal"
        )
        let env = MockSystemEnvironment()
        env.runningApps = ["com.apple.Terminal"]

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .inactiveSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.dismissed() == 1)
        #expect(cb.markedRead() == [session.id])
        #expect(env.shellCommands.contains { $0.1.contains("-b") && $0.1.contains("com.apple.Terminal") })
    }

    @Test("Inactive session without conversationId falls back to focus")
    func inactiveSessionWithoutConversationIdFallsToFocus() {
        let session = makeSession(
            conversationId: nil,
            status: .completed,
            pid: 12345
        )
        let env = MockSystemEnvironment()
        env.guiApps = [12345: "com.apple.Terminal"]
        env.ttys = [12345: "/dev/ttys042"]

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .inactiveSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.dismissed() == 1)
        #expect(env.shellCommands.contains { $0.1.contains("-b") && $0.1.contains("com.apple.Terminal") })
    }

    @Test("Recall result with active session focuses it")
    func recallResultWithActiveSessionFocuses() {
        let session = makeSession(status: .idle, pid: 12345)
        let env = MockSystemEnvironment()
        env.guiApps = [12345: "com.apple.Terminal"]
        env.ttys = [12345: "/dev/ttys042"]

        let result = RecallResult(
            agent: "claude",
            role: "assistant",
            sessionId: "abc-123",
            project: "/tmp",
            timestamp: Date().timeIntervalSince1970,
            score: 0.95,
            resumeCmd: "claude --resume abc-123",
            text: "some text"
        )

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .recallResult(result, matchedSession: session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.markedRead() == [session.id])
        #expect(cb.remembered() == [session.id])
        #expect(cb.dismissed() == 1)
    }

    @Test("Recall result resumes using resumeCmd and dismisses")
    func recallResultResumes() {
        let env = MockSystemEnvironment()
        env.runningApps = ["com.apple.Terminal"]

        let result = RecallResult(
            agent: "claude",
            role: "assistant",
            sessionId: "abc-123",
            project: "/tmp",
            timestamp: Date().timeIntervalSince1970,
            score: 0.95,
            resumeCmd: "claude --resume abc-123",
            text: "some text"
        )

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .recallResult(result),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.dismissed() == 1)
        #expect(env.shellCommands.contains { $0.1.contains("com.apple.Terminal") })
    }

    @Test("Recall result with inactive matched session resumes using session host app")
    func recallResultWithInactiveMatchedSessionUsesHostApp() {
        let session = makeSession(
            conversationId: "abc-123",
            status: .completed,
            pid: nil,
            hostAppBundleId: "com.todesktop.230313mzl4w4u92"
        )
        let env = MockSystemEnvironment()
        // Set a different frontmost app to prove we use the session's host app, not frontmost
        env.frontmostApp = "com.apple.Terminal"
        env.runningApps = ["com.apple.Terminal", "com.todesktop.230313mzl4w4u92"]

        let result = RecallResult(
            agent: "claude",
            role: "assistant",
            sessionId: "abc-123",
            project: "/tmp",
            timestamp: Date().timeIntervalSince1970,
            score: 0.95,
            resumeCmd: "claude --resume abc-123",
            text: "some text"
        )

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .recallResult(result, matchedSession: session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.dismissed() == 1)
        // Verify resume dispatched to the session's host app, not the frontmost terminal
        #expect(env.shellCommands.contains { $0.1.contains("com.todesktop.230313mzl4w4u92") })
        #expect(!env.shellCommands.contains { $0.1.contains("com.apple.Terminal") })
    }

    @Test("Recall result copies to clipboard when no terminal available")
    func recallResultFallsBackToClipboard() {
        let env = MockSystemEnvironment()
        // Non-existent project directory — resume will fail

        let result = RecallResult(
            agent: "claude",
            role: "assistant",
            sessionId: "abc-123",
            project: "/nonexistent/path",
            timestamp: Date().timeIntervalSince1970,
            score: 0.95,
            resumeCmd: "claude --resume abc-123",
            text: "some text"
        )

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .recallResult(result),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.dismissed() == 1)
        #expect(NSPasteboard.general.string(forType: .string) == "cd '/nonexistent/path' && claude --resume abc-123")
    }

    @Test("Recall result passes resumeCmd through directly to resume")
    func recallResultPassesResumeCmdDirectly() {
        // resumeCmd is now a bare command (no cd prefix) — verify it's passed through as-is
        let script = TerminalController.buildResumeScript(
            command: "claude --resume abc-123",
            directory: "/tmp",
            app: .terminal
        )
        #expect(script?.contains("cd /tmp && claude --resume abc-123") == true)
    }

    @Test("compoundShellCommand constructs cd prefix")
    func compoundShellCommandWithDirectory() {
        let result = SessionAction.compoundShellCommand("claude --resume abc", directory: "/tmp/project")
        #expect(result == "cd '/tmp/project' && claude --resume abc")
    }

    @Test("compoundShellCommand with empty directory returns bare command")
    func compoundShellCommandEmptyDirectory() {
        let result = SessionAction.compoundShellCommand("claude --resume abc", directory: "")
        #expect(result == "claude --resume abc")
    }

    @Test("compoundShellCommand escapes spaces in directory")
    func compoundShellCommandSpacesInPath() {
        let result = SessionAction.compoundShellCommand("claude --resume abc", directory: "/tmp/my project")
        #expect(result == "cd '/tmp/my project' && claude --resume abc")
    }

    @Test("compoundShellCommand escapes single quotes in directory")
    func compoundShellCommandSingleQuotes() {
        let result = SessionAction.compoundShellCommand("claude --resume abc", directory: "/tmp/it's a project")
        #expect(result == "cd '/tmp/it'\\''s a project' && claude --resume abc")
    }

    @Test("Inactive VS Code session resume uses session.directory, ignores hostWorkspaceFolder")
    func inactiveVSCodeResumeIgnoresHostWorkspaceFolder() {
        let session = makeSession(
            conversationId: "abc-123",
            directory: "/tmp",
            hostWorkspaceFolder: "/tmp/host-workspace",
            status: .completed,
            pid: nil,
            hostAppBundleId: "com.microsoft.VSCode"
        )
        let env = MockSystemEnvironment()
        env.runningApps = ["com.microsoft.VSCode"]

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .inactiveSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.dismissed() == 1)
        // Resume must use session.directory, not hostWorkspaceFolder
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.microsoft.VSCode", "/tmp"] })
        #expect(!env.shellCommands.contains { $0.1.contains("/tmp/host-workspace") })
    }

    @Test("Resume failure copies command to clipboard")
    func resumeFailureCopiesCommandToClipboard() {
        let session = makeSession(
            conversationId: "abc-123",
            directory: "/tmp",
            status: .completed,
            pid: nil,
            hostAppBundleId: nil
        )
        let env = MockSystemEnvironment()

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .inactiveSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.dismissed() == 1)
        #expect(NSPasteboard.general.string(forType: .string) == "cd '/tmp' && claude --resume abc-123")
    }

    // MARK: - Fork Session Routing

    @Test("forkSession for inactive Claude session dispatches resume with --fork-session")
    func forkSessionInactiveClaudeDispatchesFork() {
        let session = makeSession(
            tool: .claude,
            conversationId: "abc-123",
            directory: "/tmp",
            status: .completed,
            pid: nil,
            hostAppBundleId: "com.apple.Terminal"
        )
        let env = MockSystemEnvironment()
        env.runningApps = ["com.apple.Terminal"]

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .forkSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.markedRead() == [session.id])
        #expect(cb.dismissed() == 1)
        // The bundleId resolution chose the session's host app and open -b activated it.
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.apple.Terminal"] })
        // Clipboard fallback should not have fired.
        #expect(NSPasteboard.general.string(forType: .string)?.contains("--fork-session") != true)
    }

    @Test("forkSession for active Claude session dispatches fork (does not focus)")
    func forkSessionActiveClaudeDispatchesFork() {
        let session = makeSession(
            tool: .claude,
            conversationId: "abc-123",
            directory: "/tmp",
            status: .idle,
            pid: 12345,
            hostAppBundleId: "com.apple.Terminal"
        )
        let env = MockSystemEnvironment()
        env.guiApps = [12345: "com.apple.Terminal"]
        env.ttys = [12345: "/dev/ttys042"]
        env.runningApps = ["com.apple.Terminal"]

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .forkSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.markedRead() == [session.id])
        #expect(cb.dismissed() == 1)
        // forkSession does NOT call rememberFocused (unlike focus paths).
        #expect(cb.remembered().isEmpty)
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.apple.Terminal"] })
    }

    @Test("forkSession for non-Claude session marks read and dismisses without dispatching")
    func forkSessionNonClaudeMarksReadAndDismisses() {
        let session = makeSession(
            tool: .gemini,
            conversationId: "ghi-789",
            directory: "/tmp",
            status: .completed,
            pid: nil,
            hostAppBundleId: "com.apple.Terminal"
        )
        let env = MockSystemEnvironment()
        env.runningApps = ["com.apple.Terminal"]

        // Clear pasteboard so we can detect a stray fallback write.
        NSPasteboard.general.clearContents()

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .forkSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        // markRead still fires (matches the resume path's bookkeeping behavior).
        #expect(cb.markedRead() == [session.id])
        // The user pressed `y` to confirm — dismiss the panel even though there's nothing to fork.
        #expect(cb.dismissed() == 1)
        #expect(env.shellCommands.isEmpty)
        #expect(env.executedScripts.isEmpty)
        // No clipboard fallback either — there's nothing meaningful to paste.
        #expect(NSPasteboard.general.string(forType: .string)?.contains("--fork-session") != true)
    }

    @Test("forkSession for Claude session without conversationId marks read and dismisses")
    func forkSessionClaudeMissingConversationIdMarksReadAndDismisses() {
        let session = makeSession(
            tool: .claude,
            conversationId: nil,
            directory: "/tmp",
            status: .completed,
            pid: nil,
            hostAppBundleId: "com.apple.Terminal"
        )
        let env = MockSystemEnvironment()
        env.runningApps = ["com.apple.Terminal"]

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .forkSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.markedRead() == [session.id])
        // The user pressed `y` to confirm — dismiss the panel even though there's nothing to fork.
        #expect(cb.dismissed() == 1)
        #expect(env.shellCommands.isEmpty)
    }

    @Test("forkSession for cmux session with surfaceId invokes cmux CLI")
    func forkSessionCmuxWithSurfaceIdInvokesCLI() {
        // Suite-level init() flips forkExecutor to sync — see top of suite.
        let surfaceId = "CCCCCCCC-0000-0000-0000-000000000001"
        let workspaceId = "AAAAAAAA-0000-0000-0000-000000000001"
        let paneId = "DDDDDDDD-0000-0000-0000-000000000001"
        let newSurfaceId = "EEEEEEEE-0000-0000-0000-000000000001"
        let cmuxBundlePath = "/tmp/seshctl-test-fixture-action/cmux.app"
        let cliDir = "\(cmuxBundlePath)/Contents/Resources/bin"
        try? FileManager.default.createDirectory(atPath: cliDir, withIntermediateDirectories: true)
        let cli = "\(cliDir)/cmux"
        if !FileManager.default.fileExists(atPath: cli) {
            FileManager.default.createFile(atPath: cli, contents: Data("#!/bin/sh\n".utf8))
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)

        let session = makeSession(
            tool: .claude,
            conversationId: "abc-123",
            directory: "/tmp",
            status: .completed,
            pid: nil,
            hostAppBundleId: "com.cmuxterm.app",
            windowId: "\(workspaceId)|\(surfaceId)"
        )
        let env = MockSystemEnvironment()
        env.runningApps = ["com.cmuxterm.app"]
        env.appBundleURLs["com.cmuxterm.app"] = URL(fileURLWithPath: cmuxBundlePath)

        let treeWithSurface = """
            {"windows":[{"workspaces":[{"panes":[{"surfaces":[
                {"id":"\(surfaceId)","pane_id":"\(paneId)"}
            ]}]}]}]}
            """
        let treeAfterCreate = """
            {"windows":[{"workspaces":[{"panes":[{"surfaces":[
                {"id":"\(surfaceId)","pane_id":"\(paneId)"},
                {"id":"\(newSurfaceId)","pane_id":"\(paneId)"}
            ]}]}]}]}
            """
        env.stdoutResponses = [
            .init(pathSuffix: "/cmux", argsContains: ["tree"], response: treeWithSurface),
            .init(pathSuffix: "/cmux", argsContains: ["tree"], response: treeWithSurface),
            .init(pathSuffix: "/cmux", argsContains: ["new-surface"], response: ""),
            .init(pathSuffix: "/cmux", argsContains: ["tree"], response: treeAfterCreate),
            // `send` exit status is now captured — must stage a successful response.
            .init(pathSuffix: "/cmux", argsContains: ["send"], response: ""),
        ]

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .forkSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.markedRead() == [session.id])
        #expect(cb.dismissed() == 1)
        // Real assertion: the cmux CLI was used to create a sibling surface
        // and send the fork command to it. Deleting forkCmuxAdjacent breaks this.
        #expect(env.shellCommands.contains {
            $0.0.hasSuffix("/cmux") && $0.1.contains("new-surface") && $0.1.contains(paneId)
        })
        #expect(env.shellCommands.contains {
            $0.0.hasSuffix("/cmux") && $0.1.contains("send") && $0.1.contains(newSurfaceId)
        })
        // No AppleScript dispatched — we replaced the keystroke path entirely.
        #expect(env.executedScripts.isEmpty)
    }

    @Test("forkSession for cmux session without surfaceId falls through to resume (no cmux CLI)")
    func forkSessionCmuxWithoutSurfaceIdFallsThrough() {
        let workspaceId = "AAAAAAAA-0000-0000-0000-000000000001"
        let session = makeSession(
            tool: .claude,
            conversationId: "abc-123",
            directory: "/tmp",
            status: .completed,
            pid: nil,
            hostAppBundleId: "com.cmuxterm.app",
            // Legacy session: windowId contains only workspace UUID, no surface part
            windowId: workspaceId
        )
        let env = MockSystemEnvironment()
        env.runningApps = ["com.cmuxterm.app"]

        let cb = makeCallbacks()
        SessionAction.execute(
            target: .forkSession(session),
            markRead: cb.markRead,
            rememberFocused: cb.rememberFocused,
            dismiss: cb.dismiss,
            environment: env
        )

        #expect(cb.markedRead() == [session.id])
        #expect(cb.dismissed() == 1)
        // Real assertion: cmux CLI is never touched on the legacy path.
        #expect(!env.shellCommands.contains { $0.0.hasSuffix("/cmux") })
        // Falls back to standard resume path (new workspace via open -b)
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.cmuxterm.app"] })
    }

    @Test("openRemote routes through coordinator when one is provided")
    @MainActor
    func openRemoteRoutesThroughCoordinator() {
        let env = MockSystemEnvironment()
        env.runningApps = ["com.google.Chrome"]
        // The coordinator's public openOrFocus(url:environment:) calls
        // BrowserController.defaultBrowser() which queries the host machine's
        // LaunchServices and is unmockable. Make the open-script provider
        // robust to whichever browser the host returns by emitting the
        // matching "<browser>:ok" sentinel for each.
        env.appleScriptOutputProvider = { script in
            // Coordinator's step-3 open script — emit the right sentinel for
            // whichever supported browser the host's default happens to be.
            if script.contains("make new tab") {
                if script.contains("Google Chrome") { return "chrome:ok" }
                if script.contains("Arc") { return "arc:ok" }
                if script.contains("Safari") { return "safari:ok" }
            }
            // Coordinator's step-1 navigate (no managed tab on first call) and
            // step-2 focus probe — both miss.
            return ""
        }
        let coordinator = RemoteBrowserCoordinator()
        let url = URL(string: "https://claude.ai/code/session_xyz")!
        var dismissed = false

        SessionAction.execute(
            target: .openRemote(url),
            markRead: { _ in },
            rememberFocused: { _ in },
            dismiss: { dismissed = true },
            environment: env,
            remoteBrowserCoordinator: coordinator
        )

        #expect(dismissed)
        // Coordinator's open script ran (proves the coordinator path was taken).
        #expect(env.executedScripts.contains { $0.contains("make new tab") })
        // No NSWorkspace fallback IF the host's default is one of our supported
        // browsers (Chrome/Arc/Safari) — open script succeeds and tab is tracked.
        // If the host's default is unsupported (e.g. Firefox), defaultBrowser()
        // returns nil and the coordinator falls through to env.openURL — in
        // which case "make new tab" would not appear in executedScripts and
        // the assertion above would already have failed. So reaching here
        // means we're in the supported-default branch.
        #expect(env.openedURLs.isEmpty)
    }

    @Test("openRemote falls back to BrowserController when no coordinator (back-compat)")
    @MainActor
    func openRemoteWithoutCoordinatorFallsBackToBrowserController() {
        let env = MockSystemEnvironment()
        env.runningApps = []  // no browsers running, focus probe is a no-op
        let url = URL(string: "https://claude.ai/code/session_xyz")!
        var dismissed = false

        SessionAction.execute(
            target: .openRemote(url),
            markRead: { _ in },
            rememberFocused: { _ in },
            dismiss: { dismissed = true },
            environment: env,
            remoteBrowserCoordinator: nil
        )

        #expect(dismissed)
        // BrowserController.focusOrOpen fell through to env.openURL because no
        // running browsers matched.
        #expect(env.openedURLs == [url])
        // No "make new tab" script ran — that's coordinator-specific behavior.
        #expect(!env.executedScripts.contains { $0.contains("make new tab") })
    }

    // MARK: - Claude desktop app deep link

    @Test("openRemote opens the claude:// deep link when the desktop app is installed")
    @MainActor
    func openRemoteUsesDesktopAppWhenInstalled() {
        let env = MockSystemEnvironment()
        env.appBundleURLs[ClaudeDesktopApp.bundleId] = URL(fileURLWithPath: "/Applications/Claude.app")
        env.runningApps = ["com.google.Chrome"]
        let coordinator = RemoteBrowserCoordinator()
        let url = URL(string: "https://claude.ai/code/session_xyz")!
        var dismissed = false

        SessionAction.execute(
            target: .openRemote(url),
            markRead: { _ in },
            rememberFocused: { _ in },
            dismiss: { dismissed = true },
            environment: env,
            remoteBrowserCoordinator: coordinator
        )

        #expect(dismissed)
        #expect(env.openedURLs == [URL(string: "claude://code/session_xyz")!])
        // Neither the coordinator nor BrowserController ran any AppleScript.
        #expect(env.executedScripts.isEmpty)
    }

    @Test("openRemote uses the desktop app without a coordinator too")
    @MainActor
    func openRemoteUsesDesktopAppWithoutCoordinator() {
        let env = MockSystemEnvironment()
        env.appBundleURLs[ClaudeDesktopApp.bundleId] = URL(fileURLWithPath: "/Applications/Claude.app")
        env.runningApps = ["com.google.Chrome"]
        let url = URL(string: "https://claude.ai/code/session_xyz")!

        SessionAction.execute(
            target: .openRemote(url),
            markRead: { _ in },
            rememberFocused: { _ in },
            dismiss: {},
            environment: env,
            remoteBrowserCoordinator: nil
        )

        #expect(env.openedURLs == [URL(string: "claude://code/session_xyz")!])
        #expect(env.executedScripts.isEmpty)
    }

    @Test("openRemote falls back to the browser when the desktop app is not installed")
    @MainActor
    func openRemoteFallsBackToBrowserWhenDesktopAppMissing() {
        let env = MockSystemEnvironment()
        // No appBundleURLs entry for ClaudeDesktopApp.bundleId → not installed.
        env.runningApps = ["com.google.Chrome"]
        env.appleScriptOutputProvider = { _ in "found" }
        let url = URL(string: "https://claude.ai/code/session_xyz")!

        SessionAction.execute(
            target: .openRemote(url),
            markRead: { _ in },
            rememberFocused: { _ in },
            dismiss: {},
            environment: env,
            remoteBrowserCoordinator: nil
        )

        // The browser focus probe ran and matched an existing tab, so nothing
        // was opened — and certainly no claude:// URL.
        #expect(!env.executedScripts.isEmpty)
        #expect(env.openedURLs.isEmpty)
    }

    @Test("openRemote falls back to the browser when the URL has no valid session id")
    @MainActor
    func openRemoteFallsBackToBrowserForUnrecognizedURL() {
        let env = MockSystemEnvironment()
        env.appBundleURLs[ClaudeDesktopApp.bundleId] = URL(fileURLWithPath: "/Applications/Claude.app")
        env.runningApps = []
        let url = URL(string: "https://claude.ai/code/not-a-session")!

        SessionAction.execute(
            target: .openRemote(url),
            markRead: { _ in },
            rememberFocused: { _ in },
            dismiss: {},
            environment: env,
            remoteBrowserCoordinator: nil
        )

        // BrowserController fell through to opening the original https URL.
        #expect(env.openedURLs == [url])
    }
}
