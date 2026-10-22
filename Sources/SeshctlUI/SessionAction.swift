import AppKit
import Foundation
import SeshctlCore

/// Represents what the user wants to act on.
public enum SessionActionTarget {
    /// An active session (has a live process) — focus its terminal tab.
    case activeSession(Session)
    /// An inactive session (completed/canceled/stale) — resume it.
    case inactiveSession(Session)
    /// An inactive or active Claude session — fork it into a new branched session in a new terminal tab. Original session is unaffected.
    case forkSession(Session)
    /// A recall search result, optionally linked to a matched session for focusing or host app resolution.
    case recallResult(RecallResult, matchedSession: Session? = nil)
    /// A remote (cloud) Claude Code session — open its web URL in the user's browser.
    case openRemote(URL)
}

/// CANONICAL ENTRY POINT — all session focus/resume actions MUST go through this type.
/// Do not create parallel code paths in AppDelegate, views, or elsewhere.
public enum SessionAction {

    /// Execute the appropriate action for the given target.
    /// - Parameters:
    ///   - target: What to act on
    ///   - markRead: Closure to mark a session as read (e.g., viewModel.markSessionRead).
    ///     Only fires for targets carrying a local `Session` — `.activeSession`,
    ///     `.inactiveSession`, and `.recallResult`. The `.openRemote` branch does
    ///     NOT invoke this closure because remote sessions are not `Session`-typed;
    ///     callers handle remote mark-read out-of-band (see
    ///     `AppDelegate.executeSessionAction`, which calls
    ///     `vm.markSelectedRowRead()` before constructing `.openRemote`).
    ///   - rememberFocused: Closure to remember the focused session (e.g., viewModel.rememberFocusedSession)
    ///   - dismiss: Closure to dismiss the panel
    public static func execute(
        target: SessionActionTarget,
        markRead: (Session) -> Void,
        rememberFocused: (Session) -> Void,
        dismiss: () -> Void,
        environment: SystemEnvironment? = nil,
        remoteBrowserCoordinator: RemoteBrowserCoordinator? = nil
    ) {
        switch target {
        case .activeSession(let session):
            focusActiveSession(session, markRead: markRead, rememberFocused: rememberFocused, dismiss: dismiss, environment: environment)

        case .inactiveSession(let session):
            resumeInactiveSession(session, markRead: markRead, dismiss: dismiss, environment: environment)

        case .forkSession(let session):
            forkSession(session, markRead: markRead, dismiss: dismiss, environment: environment)

        case .recallResult(let result, let matchedSession):
            handleRecallResult(result, matchedSession: matchedSession, markRead: markRead, rememberFocused: rememberFocused, dismiss: dismiss, environment: environment)

        case .openRemote(let url):
            openRemote(url, dismiss: dismiss, environment: environment, remoteBrowserCoordinator: remoteBrowserCoordinator)
        }
    }

    // MARK: - Private

    private static func focusActiveSession(
        _ session: Session,
        markRead: (Session) -> Void,
        rememberFocused: (Session) -> Void,
        dismiss: () -> Void,
        environment: SystemEnvironment? = nil
    ) {
        markRead(session)
        rememberFocused(session)
        // Hide the panel first to avoid resignKey() racing with app activation,
        // which can cause a focus flicker (target app activates → panel loses key
        // → macOS briefly refocuses another window).
        dismiss()
        let bundleId = TerminalController.resolveAppBundleId(session: session, environment: environment)
        if let pid = session.pid {
            TerminalController.focus(pid: pid, directory: session.directory, launchDirectory: session.launchDirectory, hostWorkspaceFolder: session.hostWorkspaceFolder, bundleId: bundleId, windowId: session.windowId, tool: session.tool, conversationId: session.conversationId, environment: environment)
        } else if session.tool == .cursor, let conversationId = session.conversationId, !conversationId.isEmpty, bundleId != nil {
            // Cursor chat sessions can have pid: nil when the row was lazy-created
            // by an update event (Cursor's per-event PPID isn't stable and isn't
            // useful for focus anyway — composer.openComposer keys on the
            // conversationId). Dispatch with a placeholder pid; the Cursor branch
            // of focusViaURIHandler ignores it.
            TerminalController.focus(pid: 0, directory: session.directory, launchDirectory: session.launchDirectory, hostWorkspaceFolder: session.hostWorkspaceFolder, bundleId: bundleId, windowId: session.windowId, tool: .cursor, conversationId: conversationId, environment: environment)
        }
    }

    private static func resumeInactiveSession(
        _ session: Session,
        markRead: (Session) -> Void,
        dismiss: () -> Void,
        environment: SystemEnvironment? = nil
    ) {
        markRead(session)
        let command = TerminalController.buildResumeCommand(session: session)
        let bundleId = TerminalController.resolveAppBundleId(session: session, environment: environment)

        if let command, TerminalController.resume(command: command, directory: session.directory, bundleId: bundleId, environment: environment) {
            dismiss()
        } else if let command {
            // Resume dispatch failed — copy command to clipboard as fallback
            copyToClipboard(compoundShellCommand(command, directory: session.directory))
            dismiss()
        } else if session.pid != nil
            || (session.tool == .cursor && (session.conversationId?.isEmpty == false))
        {
            // Fall through to focus. Two cases:
            //  - Non-Cursor session with a PID: traditional terminal focus by PID.
            //  - Cursor chat session (PID may be nil because lazy-create can't
            //    capture a stable PID): focus by conversationId via
            //    composer.openComposer. focusActiveSession handles both.
            // markRead was already called at the top of resumeInactiveSession;
            // rememberFocused is intentionally skipped for resume paths.
            focusActiveSession(session, markRead: { _ in }, rememberFocused: { _ in }, dismiss: dismiss, environment: environment)
        }
    }

    private static func forkSession(
        _ session: Session,
        markRead: (Session) -> Void,
        dismiss: () -> Void,
        environment: SystemEnvironment? = nil
    ) {
        markRead(session)
        let command = TerminalController.buildForkCommand(session: session)
        let bundleId = TerminalController.resolveAppBundleId(session: session, environment: environment)

        if let command, TerminalController.fork(
            command: command,
            directory: session.directory,
            bundleId: bundleId,
            sourceWindowId: session.windowId,
            environment: environment
        ) {
            dismiss()
        } else if let command {
            // Fork dispatch failed — copy command to clipboard as fallback.
            // NOTE: For cmux sessions, `fork(...)` returns true synchronously the
            // moment work is dispatched to the background queue, so this branch
            // only fires when cmux's CLI prerequisites are missing AND the inner
            // `resume(...)` fallback also fails — i.e. a non-cmux fork that
            // synchronously fails at `resume(...)`. The rare double-failure
            // inside the cmux closure is silent (see TerminalController.fork
            // doc-comment); fix lives there if it ever surfaces in practice.
            copyToClipboard(compoundShellCommand(command, directory: session.directory))
            dismiss()
        } else {
            // No fork command (non-Claude tool or missing conversationId) — the user
            // pressed `y` to confirm; dismiss cleanly so the panel doesn't linger.
            dismiss()
        }
    }

    private static func handleRecallResult(
        _ result: RecallResult,
        matchedSession: Session?,
        markRead: (Session) -> Void,
        rememberFocused: (Session) -> Void,
        dismiss: () -> Void,
        environment: SystemEnvironment? = nil
    ) {
        // If recall result matches an active session, focus it directly
        if let session = matchedSession, session.isActive {
            focusActiveSession(session, markRead: markRead, rememberFocused: rememberFocused, dismiss: dismiss, environment: environment)
            return
        }

        // Resolve the target app: prefer the matched session's host app, fall back to frontmost terminal
        let bundleId: String?
        if let session = matchedSession {
            bundleId = TerminalController.resolveAppBundleId(session: session, environment: environment)
        } else {
            bundleId = TerminalController.detectFrontmostTerminal(environment: environment)
        }

        if FileManager.default.fileExists(atPath: result.project),
           TerminalController.resume(command: result.resumeCmd, directory: result.project, bundleId: bundleId, environment: environment) {
            dismiss()
        } else {
            // Clipboard fallback: construct compound command so user can paste and run directly
            copyToClipboard(compoundShellCommand(result.resumeCmd, directory: result.project))
            dismiss()
        }
    }

    /// Open a remote (cloud) Claude Code session.
    ///
    /// When the Claude desktop app is installed and `url` is a claude.ai
    /// session URL, open `claude://code/<id>` via `env.openURL` instead — the
    /// app switches its single window to the session, so no browser tabs pile
    /// up. The deep link is undocumented (see `ClaudeDesktopApp`), so the
    /// browser path below stays the fallback.
    ///
    /// Otherwise, if a `RemoteBrowserCoordinator`
    /// is provided, route through it so successive flips between sessions
    /// reuse a single managed tab. Otherwise fall back to the stateless
    /// `BrowserController.focusOrOpen` (Phase 1 behavior — focus existing tab
    /// or open a new one in the default browser).
    ///
    /// Dismisses the panel first so the handoff feels snappy and the browser
    /// takes foreground without fighting seshctl for key-window state.
    ///
    /// `RemoteBrowserCoordinator` is `@MainActor`, but `SessionAction.execute`
    /// is not actor-isolated; the `assumeIsolated` shim asserts the caller is
    /// on the main thread (true for AppDelegate dispatch and `@MainActor` test
    /// methods) without rippling `@MainActor` through every action target.
    private static func openRemote(
        _ url: URL,
        dismiss: () -> Void,
        environment: SystemEnvironment? = nil,
        remoteBrowserCoordinator: RemoteBrowserCoordinator? = nil
    ) {
        dismiss()
        let env = environment ?? TerminalController.environment
        if env.appBundleURL(forBundleId: ClaudeDesktopApp.bundleId) != nil,
           let desktopURL = ClaudeDesktopApp.sessionURL(fromWebURL: url) {
            env.openURL(desktopURL)
            return
        }
        if let coordinator = remoteBrowserCoordinator {
            MainActor.assumeIsolated {
                coordinator.openOrFocus(url: url, environment: environment)
            }
        } else {
            BrowserController.focusOrOpen(url: url, environment: environment)
        }
    }

    /// Build a compound shell command suitable for clipboard pasting.
    /// Wraps the directory in single quotes to handle spaces and metacharacters.
    static func compoundShellCommand(_ command: String, directory: String) -> String {
        guard !directory.isEmpty else { return command }
        let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(quoted) && \(command)"
    }

    private static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
