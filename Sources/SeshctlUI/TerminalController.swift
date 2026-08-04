import AppKit
import Foundation
import SeshctlCore

// MARK: - System Environment Protocol

/// Abstracts system calls so TerminalController can be tested without real processes.
public protocol SystemEnvironment: Sendable {
    /// Get the parent PID of a process. Returns 0 on failure.
    func parentPid(of pid: pid_t) -> pid_t

    /// Get the bundle ID of the GUI app owning a PID, or nil if not a GUI app.
    func guiAppBundleId(for pid: pid_t) -> String?

    /// Get the localized name of the GUI app owning a PID.
    func guiAppName(for pid: pid_t) -> String?

    /// Get the TTY device path for a PID (e.g., "/dev/ttys000").
    func tty(for pid: Int) -> String?

    /// Get the bundle ID of the frontmost application, or nil.
    func frontmostAppBundleId() -> String?

    /// Get bundle IDs of all currently running apps.
    func runningAppBundleIds() -> [String]

    /// Activate the app with the given bundle ID.
    func activateApp(bundleId: String)

    /// Run an AppleScript string.
    func runAppleScript(_ script: String)

    /// Run an AppleScript and capture its stdout. Returns `nil` if osascript
    /// exits non-zero or fails to launch. Trimmed of leading/trailing whitespace.
    /// Used by callers that need to branch on AppleScript output (e.g. probing
    /// browsers for an existing tab match).
    func runAppleScriptCapturingOutput(_ script: String) -> String?

    /// Run a shell command with arguments.
    func runShellCommand(_ path: String, args: [String])

    /// Run a shell command and return its stdout (UTF-8, trimmed). Returns nil on
    /// non-zero exit, missing executable, decode failure, or timeout. Stderr is
    /// discarded. Used for short, deterministic CLI calls (e.g. `cmux tree --json`).
    /// `timeout` bounds the wait; on expiry the process is terminated and nil is
    /// returned, so callers running on a hot thread (e.g. @MainActor) can't be
    /// wedged by an unresponsive daemon.
    func runShellCommandCapturingStdout(_ path: String, args: [String], timeout: TimeInterval) -> String?

    /// Resolve the on-disk bundle URL for a registered macOS app, or nil if the
    /// app is not installed / not registered with Launch Services.
    func appBundleURL(forBundleId bundleId: String) -> URL?

    /// Open a URL in the user's default handler (typically the default browser).
    func openURL(_ url: URL)
}

// MARK: - Real System Environment

public struct RealSystemEnvironment: SystemEnvironment {
    public init() {}

    public func parentPid(of pid: pid_t) -> pid_t {
        pid_t(RealProcessInfoProvider().parentPid(of: Int(pid)))
    }

    public func guiAppBundleId(for pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else { return nil }
        return app.bundleIdentifier
    }

    public func guiAppName(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    public func tty(for pid: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "tty="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let tty = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tty, !tty.isEmpty else { return nil }
        return "/dev/\(tty)"
    }

    public func frontmostAppBundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    public func runningAppBundleIds() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    }

    public func activateApp(bundleId: String) {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleId }?
            .activate()
    }

    public func runAppleScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    public func runAppleScriptCapturingOutput(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func runShellCommand(_ path: String, args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        process.waitUntilExit()
    }

    public func runShellCommandCapturingStdout(_ path: String, args: [String], timeout: TimeInterval) -> String? {
        guard let result = ShellRunner.run(path: path, args: args, timeout: timeout),
              result.status == 0 else { return nil }
        return result.stdout
    }

    public func appBundleURL(forBundleId bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    public func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Terminal Controller

public enum TerminalController {
    nonisolated(unsafe) public static var environment: SystemEnvironment = RealSystemEnvironment()

    /// Test seam for the async dispatch in `fork(...)`. Production uses the
    /// global concurrent queue so the cmux CLI work doesn't block the calling
    /// thread (typically @MainActor); tests override with a synchronous closure
    /// so CLI-sequence assertions are deterministic. The work closure is
    /// `@Sendable` because production hands it to `DispatchQueue.global().async`,
    /// which requires it; all captured values at the call site (Strings,
    /// CmuxWindowID, the Sendable SystemEnvironment) already satisfy this.
    nonisolated(unsafe) static var forkExecutor: (@escaping @Sendable () -> Void) -> Void = {
        DispatchQueue.global().async(execute: $0)
    }

    // MARK: - Focus

    /// CANONICAL ENTRY POINT — all terminal focus actions MUST go through this method.
    /// Do not create parallel code paths.
    /// - Parameter hostWorkspaceFolder: Preferred input for URI-handler apps (VS Code family): the workspace folder of the VS Code window hosting the live terminal, recorded by the companion extension at terminal-open time. Takes precedence over `launchDirectory`. Ignored by AppleScript-based terminals.
    /// - Parameter launchDirectory: Original directory the session was launched in. Fallback for URI-handler apps when `hostWorkspaceFolder` is unavailable (e.g. sessions recorded before the extension was installed). Ignored by AppleScript-based terminals.
    /// - Parameter tool: When set to `.cursor` alongside a non-empty `conversationId`, the URI-handler path dispatches `/focus-chat?id=<conversationId>` instead of `/focus-terminal?pid=<pid>` so Cursor's companion extension can call `composer.openComposer(id)` and switch to the exact chat thread. All other combinations fall through to the standard terminal-PID focus URI.
    /// - Parameter conversationId: See `tool`.
    public static func focus(pid: Int, directory: String, launchDirectory: String?, hostWorkspaceFolder: String? = nil, bundleId knownBundleId: String? = nil, windowId: String? = nil, tool: SessionTool? = nil, conversationId: String? = nil, environment env: SystemEnvironment? = nil) {
        let env = env ?? Self.environment
        guard let bundleId = knownBundleId ?? findAppBundleId(for: pid, env: env) else { return }

        if let app = TerminalApp.from(bundleId: bundleId) {
            if app.supportsURIHandler {
                // Precedence: hostWorkspaceFolder > launchDirectory > directory.
                let targetDir: String
                if let host = hostWorkspaceFolder, !host.isEmpty {
                    targetDir = host
                } else if let launch = launchDirectory, !launch.isEmpty {
                    targetDir = launch
                } else {
                    targetDir = directory
                }
                focusViaURIHandler(pid: pid, directory: targetDir, bundleId: bundleId, tool: tool, conversationId: conversationId, env: env)
                return
            }
            if app.supportsAppleScriptFocus {
                focusTerminal(pid: pid, directory: directory, bundleId: bundleId, windowId: windowId, env: env)
                return
            }
        }

        // Generic fallback for unknown apps
        let tty = env.tty(for: pid)
        if let script = buildFocusScript(
            app: TerminalApp.from(bundleId: bundleId),
            appName: appName(for: pid, bundleId: bundleId, env: env),
            tty: tty,
            directory: directory
        ) {
            env.runAppleScript(script)
        } else {
            env.activateApp(bundleId: bundleId)
        }
    }

    // MARK: - Resume

    /// CANONICAL ENTRY POINT — all terminal resume actions MUST go through this method.
    /// Do not create parallel code paths.
    @discardableResult
    public static func resume(
        command: String,
        directory: String,
        bundleId: String?,
        environment env: SystemEnvironment? = nil
    ) -> Bool {
        let env = env ?? Self.environment
        guard let bundleId else { return false }
        guard FileManager.default.fileExists(atPath: directory) else { return false }

        if let app = TerminalApp.from(bundleId: bundleId) {
            if app.supportsURIHandler {
                return resumeInVSCode(command: command, directory: directory, bundleId: bundleId, env: env)
            }
            if app.supportsAppleScriptResume {
                return resumeInTerminal(command: command, directory: directory, bundleId: bundleId, env: env)
            }
        }

        return false
    }

    // MARK: - Resume Command Building

    /// Build a resume command from a session's stored data.
    /// Returns nil if the session has no conversationId.
    /// Cursor chat sessions have no shell-resume CLI — focus is the resume
    /// action — so this returns nil for `.cursor` regardless of conversationId.
    public static func buildResumeCommand(session: Session) -> String? {
        guard let conversationId = session.conversationId else { return nil }

        let binary: String
        switch session.tool {
        case .claude: binary = "claude"
        case .gemini: binary = "gemini"
        case .codex: binary = "codex"
        case .pi: binary = "pi"
        case .cursor: return nil
        }

        var parts = [binary]
        if let args = session.launchArgs, !args.isEmpty {
            let sanitized = stripUnshellableFlags(args)
            if !sanitized.isEmpty {
                parts.append(sanitized)
            }
        }
        switch session.tool {
        case .codex:
            parts.append("resume")
        case .pi:
            // Pi's `--session` accepts a full path or a partial UUID.
            parts.append("--session")
        case .claude, .gemini:
            parts.append("--resume")
        case .cursor:
            return nil  // Unreachable — earlier switch already returned nil for .cursor.
        }
        parts.append(conversationId)

        return parts.joined(separator: " ")
    }

    /// Strip launch flags whose values can't safely round-trip through a shell
    /// command string. `launchArgs` comes from `ps -o args=`, which discards
    /// the kernel argv boundaries — JSON values with embedded spaces, braces,
    /// and commas re-emerge as text that bash will brace-expand or word-split
    /// when pasted. Specifically:
    /// - `--session-id <UUID>`: cmux-injected per-launch random; useless for
    ///   resume since `--resume <conversationId>` already names the session.
    /// - `--settings <JSON>`: cmux-injected hook config; the new cmux tab will
    ///   re-inject hooks on its own spawn, so re-passing them is at best a
    ///   no-op and at worst a paste that mangles into nonsense.
    static func stripUnshellableFlags(_ args: String) -> String {
        var result = stripFlagWithUUIDValue(args, flag: "--session-id")
        result = stripFlagWithJSONValue(result, flag: "--settings")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Remove `<flag> <UUID>` (8-4-4-4-12 hex form). Returns the input unchanged
    /// if the flag isn't present or isn't followed by a UUID-shaped token.
    /// Requires a word boundary (start-of-string or whitespace) before the flag
    /// so suffix-matches like `--my-session-id` aren't clipped to `--my`.
    static func stripFlagWithUUIDValue(_ args: String, flag: String) -> String {
        let escapedFlag = NSRegularExpression.escapedPattern(for: flag)
        let pattern = "(?<=^|\\s)\(escapedFlag) [0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return args }
        let range = NSRange(args.startIndex..<args.endIndex, in: args)
        return regex.stringByReplacingMatches(in: args, range: range, withTemplate: "")
    }

    /// Remove `<flag> {…}` where the JSON value's end is found by brace
    /// counting with quote-state awareness. Returns the input unchanged if the
    /// flag isn't present, isn't followed by `{`, or has unbalanced braces.
    /// Requires a word boundary (start-of-string or whitespace) before the flag
    /// so suffix-matches like `--my-settings` aren't clipped to `--my`.
    static func stripFlagWithJSONValue(_ args: String, flag: String) -> String {
        let prefix = "\(flag) "
        // First try a whitespace-prefixed match anywhere in the string; that way
        // we can place flagStart right after the boundary char and preserve it.
        let flagStart: String.Index
        if let spaced = args.range(of: " \(prefix)") {
            flagStart = args.index(after: spaced.lowerBound)
        } else if args.hasPrefix(prefix) {
            flagStart = args.startIndex
        } else {
            return args
        }
        let valueStart = args.index(flagStart, offsetBy: prefix.count)
        guard valueStart < args.endIndex, args[valueStart] == "{" else { return args }

        var depth = 0
        var inString = false
        var escaped = false
        var i = valueStart
        while i < args.endIndex {
            let c = args[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let valueEnd = args.index(after: i)
                    var result = args
                    result.removeSubrange(flagStart..<valueEnd)
                    return result
                }
            }
            i = args.index(after: i)
        }
        return args
    }

    /// Build a fork command from a session's stored data.
    /// Returns nil for non-Claude tools or when the session has no conversationId.
    /// `--fork-session` is a Claude-only flag and only valid alongside `--resume`.
    public static func buildForkCommand(session: Session) -> String? {
        guard session.tool == .claude else { return nil }
        guard let resume = buildResumeCommand(session: session) else { return nil }
        return resume + " --fork-session"
    }

    // MARK: - Fork

    /// CANONICAL ENTRY POINT — all session-fork actions MUST go through this method.
    /// Do not create parallel code paths.
    ///
    /// For cmux sessions whose `sourceWindowId` carries a surface UUID, dispatches
    /// via cmux's Unix-socket CLI to create a sibling surface in the same pane and
    /// type the fork command into it. For all other cases (non-cmux app, legacy
    /// windowId without surface, CLI missing, surface stale, CLI auth fails),
    /// falls through to `resume(...)` so the user always gets some forked session.
    ///
    /// **Return semantics — important.** For the cmux fast path, `true` means
    /// "dispatched onto the background queue", **not** "succeeded". The closure's
    /// own `forkCmuxAdjacent` → `resume(...)` fallback is the user-visible
    /// success/failure signal. Callers that branch on `false` (e.g. the
    /// clipboard fallback in `SessionAction.forkSession`) only handle the
    /// synchronous early-return cases (nil bundleId, non-cmux `resume(...)`
    /// returning false), not the rare double-failure inside the closure where
    /// both `forkCmuxAdjacent` AND its `resume(...)` retry fail. That double
    /// failure is silent today; if it surfaces in practice, copy the command
    /// to the clipboard from inside the closure on a `@MainActor` hop.
    @discardableResult
    public static func fork(
        command: String,
        directory: String,
        bundleId: String?,
        sourceWindowId: String?,
        environment env: SystemEnvironment? = nil
    ) -> Bool {
        let env = env ?? Self.environment
        guard let bundleId else { return false }

        // Cmux CLI dispatch runs four serial subprocess calls; we keep them
        // off the calling thread (typically @MainActor in AppDelegate) so a
        // wedged daemon can't freeze the panel. On any failure inside the
        // dispatch chain we fall back to `resume(...)` from the same queue.
        // Returning true synchronously matches the existing `resume(...)`
        // semantics — the caller dismisses optimistically and any failure is
        // best-effort handled in the background.
        if TerminalApp.from(bundleId: bundleId) == .cmux,
           let parsed = CmuxWindowID.parse(sourceWindowId),
           let surfaceId = parsed.surfaceId {
            forkExecutor {
                if !forkCmuxAdjacent(
                    command: command,
                    directory: directory,
                    workspaceId: parsed.workspaceId,
                    surfaceId: surfaceId,
                    bundleId: bundleId,
                    env: env
                ) {
                    _ = resume(command: command, directory: directory, bundleId: bundleId, environment: env)
                }
            }
            return true
        }

        return resume(command: command, directory: directory, bundleId: bundleId, environment: env)
    }

    // MARK: - Frontmost Terminal Detection

    /// Find the frontmost known terminal app. Returns its bundle ID, or nil if none running.
    public static func detectFrontmostTerminal(environment env: SystemEnvironment? = nil) -> String? {
        let env = env ?? Self.environment
        let running = env.runningAppBundleIds()
        if let frontApp = env.frontmostAppBundleId(),
           TerminalApp.from(bundleId: frontApp) != nil {
            return frontApp
        }
        return TerminalApp.allCases.map(\.bundleId).first { running.contains($0) }
    }

    // MARK: - Unified App Resolution

    /// Resolve the best bundle ID for a session: DB value, then PID walk, then frontmost terminal.
    public static func resolveAppBundleId(session: Session, environment env: SystemEnvironment? = nil) -> String? {
        let env = env ?? Self.environment
        if let bundleId = session.hostAppBundleId, !bundleId.isEmpty {
            return bundleId
        }
        if let pid = session.pid, let bundleId = findAppBundleId(for: pid, env: env) {
            return bundleId
        }
        return detectFrontmostTerminal(environment: env)
    }

    // MARK: - App Discovery (internal for testing)

    /// Walk the process tree to find the GUI app, with fallback to running known terminals.
    static func findAppBundleId(for pid: Int, env: SystemEnvironment) -> String? {
        var currentPid = pid_t(pid)
        for _ in 0..<10 {
            if let bundleId = env.guiAppBundleId(for: currentPid) {
                return bundleId
            }
            let parent = env.parentPid(of: currentPid)
            if parent <= 1 || parent == currentPid { break }
            currentPid = parent
        }

        // Fallback: check if any known terminal app is running
        let running = Set(env.runningAppBundleIds())
        return TerminalApp.allCases.map(\.bundleId).first { running.contains($0) }
    }

    // MARK: - Script Generation (internal for testing)

    /// Build the AppleScript to focus the right window. Returns nil if unable.
    /// Note: Terminal/iTerm2 scripts omit `activate` — callers must bring the
    /// app forward first (e.g. via `open -b`).
    static func buildFocusScript(
        app: TerminalApp?,
        appName: String,
        tty: String?,
        directory: String,
        windowId: String? = nil
    ) -> String? {
        let dirName = (directory as NSString).lastPathComponent
        let escapedDirName = escapeForAppleScript(dirName)

        switch app {
        case .terminal:
            guard let tty else { return nil }
            let escapedTty = escapeForAppleScript(tty)
            return """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(escapedTty)" then
                                set selected of t to true
                                set index of w to 1
                                return
                            end if
                        end repeat
                    end repeat
                end tell
                """

        case .iterm2:
            guard let tty else { return nil }
            let escapedTty = escapeForAppleScript(tty)
            return """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(escapedTty)" then
                                    select s
                                    select w
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """

        case .ghostty:
            let escapedDir = escapeForAppleScript(directory)
            // Try terminal ID first (exact match), then fall back to directory matching.
            // The ID may be stale after resume (new tab gets a new ID), so both paths
            // are always included in the script.
            let idMatchBlock: String
            if let windowId {
                let escapedId = escapeForAppleScript(windowId)
                idMatchBlock = """
                        -- Try exact terminal ID match first
                        repeat with w in windows
                            repeat with t in tabs of w
                                repeat with trm in terminals of t
                                    if id of trm is "\(escapedId)" then
                                        select tab t
                                        activate window w
                                        return
                                    end if
                                end repeat
                            end repeat
                        end repeat
                    """
            } else {
                idMatchBlock = ""
            }
            return """
                tell application "Ghostty"
                \(idMatchBlock)
                    -- Fall back to directory matching: prefer selected tab, then scan all
                    if (count of windows) > 0 then
                        set selTab to selected tab of front window
                        repeat with trm in terminals of selTab
                            if working directory of trm is "\(escapedDir)" then
                                activate window (front window)
                                return
                            end if
                        end repeat
                    end if
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with trm in terminals of t
                                if working directory of trm is "\(escapedDir)" then
                                    select tab t
                                    activate window w
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """

        case .warp:
            if let tty {
                let ttyName = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
                let escapedTtyName = escapeForAppleScript(ttyName)
                return """
                    set ttyName to "\(escapedTtyName)"
                    set shellScript to "H=$(pgrep -P $(pgrep -f 'Warp.app/Contents/MacOS/stable' | head -1) | head -1) 2>/dev/null; pgrep -P $H 2>/dev/null | xargs ps -o tty= -p 2>/dev/null | tr -d ' ' | sort | grep -n " & quoted form of ttyName & " | head -1 | cut -d: -f1"
                    try
                        set tabPos to (do shell script shellScript) as integer
                    on error
                        set tabPos to 0
                    end try
                    delay 0.3
                    tell application "System Events"
                        tell process "Warp"
                            if tabPos > 0 and tabPos < 10 then
                                keystroke (tabPos as text) using command down
                            end if
                        end tell
                    end tell
                    """
            }
            // No TTY available — fall back to window name matching
            return """
                tell application "System Events"
                    tell process "Warp"
                        set targetWindow to missing value
                        repeat with w in windows
                            if name of w contains "\(escapedDirName)" then
                                set targetWindow to w
                                exit repeat
                            end if
                        end repeat
                        if targetWindow is not missing value then
                            perform action "AXRaise" of targetWindow
                        end if
                    end tell
                end tell
                """

        case .cmux:
            // cmux's AppleScript model is two-level: each `window` contains
            // `tab`s (vertical-list workspaces, id = $CMUX_WORKSPACE_ID) and
            // each tab contains `terminal`s (horizontal tabs within a
            // workspace, id = $CMUX_SURFACE_ID). The outer repeat selects the
            // right workspace; a nested repeat then `focus`es the matching
            // terminal so the horizontal tab is raised too. Backward-compat:
            // pre-upgrade sessions stored just the workspace UUID with no
            // pipe, so we skip the inner block when the surface part is
            // missing.
            guard let parsed = CmuxWindowID.parse(windowId) else { return nil }
            let escapedWorkspaceId = escapeForAppleScript(parsed.workspaceId)
            let surfaceBlock: String
            if let surfaceId = parsed.surfaceId {
                let escapedSurfaceId = escapeForAppleScript(surfaceId)
                surfaceBlock = """

                                repeat with tr in terminals of t
                                    if id of tr is "\(escapedSurfaceId)" then
                                        focus tr
                                        return
                                    end if
                                end repeat
                """
            } else {
                surfaceBlock = ""
            }
            return """
                tell application "cmux"
                    activate
                    repeat with w in windows
                        repeat with t in tabs of w
                            if id of t is "\(escapedWorkspaceId)" then
                                activate window w
                                select tab t\(surfaceBlock)
                                return
                            end if
                        end repeat
                    end repeat
                end tell
                """

        case .vscode, .vscodeInsiders, .cursor, nil:
            let escapedName = escapeForAppleScript(appName)
            return """
                tell application "System Events"
                    tell process "\(escapedName)"
                        set frontmost to true
                        set targetWindow to missing value
                        repeat with w in windows
                            if name of w contains "\(escapedDirName)" then
                                set targetWindow to w
                                exit repeat
                            end if
                        end repeat
                        if targetWindow is not missing value then
                            perform action "AXRaise" of targetWindow
                        end if
                    end tell
                end tell
                """
        }
    }

    /// Build AppleScript to open a new terminal tab and run a command.
    static func buildResumeScript(command: String, directory: String, app: TerminalApp?) -> String? {
        let escapedCmd = escapeForAppleScript(command)
        let escapedDir = escapeForAppleScript(directory)
        let fullCmd = "cd \(escapedDir) && \(escapedCmd)"

        switch app {
        case .terminal:
            // Terminal.app has no native AppleScript "create tab" API (unlike iTerm2's
            // `create tab with default profile`), so we simulate Cmd+T via System Events.
            return """
                tell application "Terminal"
                    activate
                    if (count of windows) > 0 then
                        tell application "System Events" to keystroke "t" using command down
                        delay 0.3
                        do script "\(fullCmd)" in selected tab of front window
                    else
                        do script "\(fullCmd)"
                    end if
                end tell
                """

        case .iterm2:
            return """
                tell application "iTerm2"
                    if (count of windows) > 0 then
                        tell current window
                            set newTab to (create tab with default profile)
                            tell current session of newTab
                                write text "\(fullCmd)"
                            end tell
                        end tell
                    else
                        create window with default profile
                        tell current session of current window
                            write text "\(fullCmd)"
                        end tell
                    end if
                end tell
                """

        case .ghostty:
            return """
                tell application "Ghostty"
                    set cfg to new surface configuration
                    set initial working directory of cfg to "\(escapedDir)"
                    set initial input of cfg to "\(escapedCmd)" & return
                    if (count of windows) > 0 then
                        new tab in front window with configuration cfg
                    else
                        new window with configuration cfg
                    end if
                end tell
                """

        case .warp:
            return """
                tell application "System Events"
                    tell process "Warp"
                        keystroke "t" using command down
                        delay 0.5
                        keystroke "\(fullCmd)"
                        delay 0.1
                        keystroke return
                    end tell
                end tell
                """

        case .cmux:
            // cmux's AppleScript surface exposes `new tab` returning a tab with
            // a `focused terminal`; `input text` pastes into the shell. We emit
            // the shell payload with a POSIX-escaped `cd`, then append `& return`
            // in AppleScript so the newline survives `escapeForAppleScript`
            // (which strips literal linefeeds).
            let shellPayload = SessionAction.compoundShellCommand(command, directory: directory)
            let escapedPayload = escapeForAppleScript(shellPayload)
            return """
                tell application "cmux"
                    activate
                    try
                        set w to front window
                    on error
                        set w to (new window)
                    end try
                    set t to (new tab in w)
                    select tab t
                    input text ("\(escapedPayload)" & return) to focused terminal of t
                end tell
                """

        case .vscode, .vscodeInsiders, .cursor, nil:
            // Unknown/unsupported terminal — can't execute commands via AppleScript
            return nil
        }
    }

    static func escapeForAppleScript(_ s: String) -> String {
        var result = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        result.unicodeScalars.removeAll { scalar in
            scalar.properties.isNoncharacterCodePoint
                || (scalar.value < 0x20 && scalar != "\t")
                || scalar.value == 0x7F
        }
        result = result.replacingOccurrences(of: "\t", with: " ")
        return result
    }

    // MARK: - Private Helpers

    private static func focusTerminal(pid: Int, directory: String, bundleId: String, windowId: String? = nil, env: SystemEnvironment) {
        let tty = env.tty(for: pid)
        let name = appName(for: pid, bundleId: bundleId, env: env)

        // 1. Bring the app forward (handles cross-Space reliably)
        env.runShellCommand("/usr/bin/open", args: ["-b", bundleId])

        // 2. Select the right tab via AppleScript
        guard let script = buildFocusScript(
            app: TerminalApp.from(bundleId: bundleId), appName: name, tty: tty, directory: directory, windowId: windowId
        ) else { return }

        env.runAppleScript(script)

        // 3. Retry after Space-switch animation completes
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            env.runAppleScript(script)
        }
    }

    /// Focus a URI-handler-based host app (VS Code family, including Cursor).
    /// Two URI shapes are emitted:
    /// - `<scheme>://julo15.seshctl/focus-chat?id=<conversationId>` when the
    ///   session's `tool == .cursor` AND `conversationId` is non-empty. The
    ///   companion extension routes this to `composer.openComposer(id)` and
    ///   switches Cursor's chat panel to that exact composer.
    /// - `<scheme>://julo15.seshctl/focus-terminal?pid=<pid>` otherwise. The
    ///   companion extension finds the terminal whose shell PID matches and
    ///   calls `terminal.show()` on it.
    ///
    /// Same `open -b` + 500ms-retry pattern in both cases.
    private static func focusViaURIHandler(pid: Int, directory: String, bundleId: String, tool: SessionTool?, conversationId: String?, env: SystemEnvironment) {
        let scheme = TerminalApp.from(bundleId: bundleId)?.uriScheme ?? "vscode"
        env.runShellCommand("/usr/bin/open", args: ["-b", bundleId, directory])

        let uri: String
        if tool == .cursor,
           let convId = conversationId,
           !convId.isEmpty {
            // Defensive encoding — composer IDs are UUIDs so this is a no-op in
            // practice, but keeps the URI well-formed if the shape ever changes.
            let encoded = convId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? convId
            uri = "\(scheme)://julo15.seshctl/focus-chat?id=\(encoded)"
        } else {
            uri = "\(scheme)://julo15.seshctl/focus-terminal?pid=\(pid)"
        }

        env.runShellCommand("/usr/bin/open", args: [uri])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            env.runShellCommand("/usr/bin/open", args: [uri])
        }
    }

    private static func resumeInVSCode(
        command: String,
        directory: String,
        bundleId: String,
        env: SystemEnvironment
    ) -> Bool {
        let scheme = TerminalApp.from(bundleId: bundleId)?.uriScheme ?? "vscode"
        env.runShellCommand("/usr/bin/open", args: ["-b", bundleId, directory])
        var queryAllowed = CharacterSet.urlQueryAllowed
        queryAllowed.remove(charactersIn: "&=+#")
        guard let encodedCmd = command.addingPercentEncoding(withAllowedCharacters: queryAllowed),
              let encodedDir = directory.addingPercentEncoding(withAllowedCharacters: queryAllowed) else {
            return false
        }
        let uri = "\(scheme)://julo15.seshctl/run-in-terminal?cmd=\(encodedCmd)&cwd=\(encodedDir)"
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            env.runShellCommand("/usr/bin/open", args: [uri])
        }
        return true
    }

    private static func resumeInTerminal(
        command: String,
        directory: String,
        bundleId: String,
        env: SystemEnvironment
    ) -> Bool {
        guard let script = buildResumeScript(command: command, directory: directory, app: TerminalApp.from(bundleId: bundleId)) else {
            return false
        }
        env.runShellCommand("/usr/bin/open", args: ["-b", bundleId])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            env.runAppleScript(script)
        }
        return true
    }

    /// Per-call timeout for cmux CLI subprocesses. Bounds main-thread blocking
    /// when the daemon is unresponsive; the dispatch chain runs four serial
    /// calls, so worst-case wait is 4× = 12s.
    static let cmuxCLITimeout: TimeInterval = 3.0

    /// Argv prefix shared by every `cmux tree --json` invocation. Centralised
    /// so a single-character divergence can't silently break only one code path.
    static func cmuxTreeArgs(workspaceId: String) -> [String] {
        ["--id-format", "both", "tree", "--json", "--workspace", workspaceId]
    }

    /// Fork a cmux session as a sibling surface in the same pane as the source.
    /// Drives cmux's Unix-socket CLI directly — no AppleScript, no Cmd-T keystroke.
    /// Returns false (so the caller can fall through to `resume`) when the cmux
    /// CLI is missing, the source surface UUID is stale, `new-surface` fails,
    /// the new surface UUID can't be recovered, or the final `send` fails.
    /// Synchronous and blocking — callers running on @MainActor MUST dispatch
    /// this off the main thread (see `fork(...)` above).
    static func forkCmuxAdjacent(
        command: String,
        directory: String,
        workspaceId: String,
        surfaceId: String,
        bundleId: String,
        env: SystemEnvironment
    ) -> Bool {
        guard let cli = cmuxCLIPath(bundleId: bundleId, env: env) else { return false }
        guard let paneId = lookupCmuxPaneId(
            cli: cli, workspaceId: workspaceId, surfaceId: surfaceId, env: env
        ) else { return false }
        guard let newSurfaceId = createCmuxSurface(
            cli: cli, workspaceId: workspaceId, paneId: paneId, env: env
        ) else { return false }

        // Bring cmux forward; idempotent if already running.
        env.runShellCommand("/usr/bin/open", args: ["-b", bundleId])

        let payload = SessionAction.compoundShellCommand(command, directory: directory) + "\n"
        // Capture `send`'s exit status — fire-and-forget would mask "empty
        // surface, no command typed" failures (bad UUID, daemon dropped the
        // socket, surface not yet ready for input). On failure the caller falls
        // through to `resume(...)`, which gives the user a working session in a
        // new tab even if it leaves an unused sibling behind.
        guard env.runShellCommandCapturingStdout(cli, args: [
            "send",
            "--workspace", workspaceId,
            "--surface", newSurfaceId,
            "--", payload,
        ], timeout: cmuxCLITimeout) != nil else { return false }
        return true
    }

    /// Resolve `<cmux.app>/Contents/Resources/bin/cmux`, or nil if cmux is not
    /// installed. Resolves the bundle via Launch Services so we don't hardcode
    /// `/Applications/...` and survive the user installing cmux elsewhere.
    static func cmuxCLIPath(bundleId: String, env: SystemEnvironment) -> String? {
        guard let bundle = env.appBundleURL(forBundleId: bundleId) else { return nil }
        let cli = bundle.appendingPathComponent("Contents/Resources/bin/cmux").path
        return FileManager.default.isExecutableFile(atPath: cli) ? cli : nil
    }

    /// Walk `cmux tree --json` to find the pane containing the source surface.
    /// Returns nil when the surface UUID is no longer present (e.g. user closed it).
    static func lookupCmuxPaneId(
        cli: String, workspaceId: String, surfaceId: String, env: SystemEnvironment
    ) -> String? {
        guard let json = env.runShellCommandCapturingStdout(
            cli, args: cmuxTreeArgs(workspaceId: workspaceId), timeout: cmuxCLITimeout
        ) else { return nil }
        return CmuxTree.findPaneId(json: json, surfaceId: surfaceId)
    }

    /// Create a sibling surface and return its UUID. Snapshot the pane's surface
    /// IDs before and after `new-surface` and return the difference — robust to
    /// the CLI not echoing the new surface UUID on stdout.
    ///
    /// The before-snapshot is REQUIRED to succeed: a nil-coerced-to-empty Set
    /// would make the diff return every existing surface in the pane, and
    /// `Set.first` could land on a live shell — typing the fork command (with a
    /// literal newline) into someone else's running session.
    ///
    /// The after-snapshot is retried a few times because cmux's daemon can take
    /// a moment to register the new surface in its tree. If the diff is still
    /// empty after retries we return nil; the caller falls through to
    /// `resume(...)`, which means a leftover empty surface in the pane plus a
    /// duplicate in a new tab — better than zero, worse than one.
    static func createCmuxSurface(
        cli: String, workspaceId: String, paneId: String, env: SystemEnvironment
    ) -> String? {
        guard let beforeJSON = env.runShellCommandCapturingStdout(
            cli, args: cmuxTreeArgs(workspaceId: workspaceId), timeout: cmuxCLITimeout
        ) else { return nil }
        let beforeIds = CmuxTree.surfaceIds(json: beforeJSON, paneId: paneId)

        // No `--id-format both` here — we don't read this stdout (the snapshot
        // diff in the loop below is what recovers the new surface UUID), so the
        // formatting flag would only add noise.
        guard env.runShellCommandCapturingStdout(cli, args: [
            "new-surface", "--workspace", workspaceId, "--pane", paneId, "--type", "terminal",
        ], timeout: cmuxCLITimeout) != nil else { return nil }

        for attempt in 0..<3 {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard let afterJSON = env.runShellCommandCapturingStdout(
                cli, args: cmuxTreeArgs(workspaceId: workspaceId), timeout: cmuxCLITimeout
            ) else { continue }
            let afterIds = CmuxTree.surfaceIds(json: afterJSON, paneId: paneId)
            if let newId = afterIds.subtracting(beforeIds).first {
                return newId
            }
        }
        return nil
    }

    private static func appName(for pid: Int, bundleId: String, env: SystemEnvironment) -> String {
        var currentPid = pid_t(pid)
        for _ in 0..<10 {
            if let name = env.guiAppName(for: currentPid) {
                return name
            }
            let parent = env.parentPid(of: currentPid)
            if parent <= 1 || parent == currentPid { break }
            currentPid = parent
        }
        return bundleId
    }
}
