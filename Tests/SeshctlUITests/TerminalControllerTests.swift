import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

// MARK: - Mock System Environment

final class MockSystemEnvironment: SystemEnvironment, @unchecked Sendable {
    var parentPids: [pid_t: pid_t] = [:]
    var guiApps: [pid_t: String] = [:]
    var appNames: [pid_t: String] = [:]
    var ttys: [Int: String] = [:]
    var frontmostApp: String? = nil
    var runningApps: [String] = []
    var activatedApps: [String] = []
    var executedScripts: [String] = []
    var shellCommands: [(String, [String])] = []
    var openedURLs: [URL] = []
    /// Optional closure that produces stdout for `runAppleScriptCapturingOutput(_:)`.
    /// If set, takes precedence over `appleScriptOutputs`.
    var appleScriptOutputProvider: ((String) -> String?)? = nil
    /// FIFO queue of return values for `runAppleScriptCapturingOutput(_:)`.
    /// Each call pops the front element. Used when `appleScriptOutputProvider` is nil.
    var appleScriptOutputs: [String?] = []
    var appBundleURLs: [String: URL] = [:]

    /// Staged stdout responses for `runShellCommandCapturingStdout`. Each entry is
    /// matched against the (path, args) tuple in order; the first match wins and
    /// is removed from the queue (so repeated calls can return different values).
    /// `path` matcher is a suffix match; `argsContains` must all be substrings of
    /// joined args. nil response = simulate non-zero exit.
    struct StdoutMatcher {
        var pathSuffix: String
        var argsContains: [String]
        var response: String?
    }
    var stdoutResponses: [StdoutMatcher] = []

    func parentPid(of pid: pid_t) -> pid_t { parentPids[pid] ?? 0 }
    func guiAppBundleId(for pid: pid_t) -> String? { guiApps[pid] }
    func guiAppName(for pid: pid_t) -> String? { appNames[pid] }
    func tty(for pid: Int) -> String? { ttys[pid] }
    func frontmostAppBundleId() -> String? { frontmostApp }
    func runningAppBundleIds() -> [String] { runningApps }
    func activateApp(bundleId: String) { activatedApps.append(bundleId) }
    func runAppleScript(_ script: String) { executedScripts.append(script) }
    func runAppleScriptCapturingOutput(_ script: String) -> String? {
        executedScripts.append(script)
        if let provider = appleScriptOutputProvider {
            return provider(script)
        }
        if !appleScriptOutputs.isEmpty {
            return appleScriptOutputs.removeFirst()
        }
        return nil
    }
    func runShellCommand(_ path: String, args: [String]) {
        shellCommands.append((path, args))
    }
    func runShellCommandCapturingStdout(_ path: String, args: [String], timeout: TimeInterval) -> String? {
        shellCommands.append((path, args))
        let joined = args.joined(separator: " ")
        if let idx = stdoutResponses.firstIndex(where: { matcher in
            path.hasSuffix(matcher.pathSuffix) && matcher.argsContains.allSatisfy { joined.contains($0) }
        }) {
            let response = stdoutResponses[idx].response
            stdoutResponses.remove(at: idx)
            return response
        }
        return nil
    }
    func appBundleURL(forBundleId bundleId: String) -> URL? { appBundleURLs[bundleId] }
    func openURL(_ url: URL) { openedURLs.append(url) }
}

// MARK: - App Discovery Tests

@Suite("TerminalController - App Discovery")
struct AppDiscoveryTests {
    @Test("Walks process tree to find VS Code")
    func findsVSCodeViaTree() {
        let env = MockSystemEnvironment()
        env.parentPids = [100: 200, 200: 300]
        env.guiApps = [300: "com.microsoft.VSCode"]

        let bundleId = TerminalController.findAppBundleId(for: 100, env: env)
        #expect(bundleId == "com.microsoft.VSCode")
    }

    @Test("Walks process tree to find Terminal.app")
    func findsTerminalViaTree() {
        let env = MockSystemEnvironment()
        env.parentPids = [100: 200, 200: 300]
        env.guiApps = [300: "com.apple.Terminal"]

        let bundleId = TerminalController.findAppBundleId(for: 100, env: env)
        #expect(bundleId == "com.apple.Terminal")
    }

    @Test("Falls back to running terminal app when tree walk fails")
    func fallsBackToRunningApp() {
        let env = MockSystemEnvironment()
        env.parentPids = [100: 200, 200: 300, 300: 0]
        env.runningApps = ["com.apple.Terminal"]

        let bundleId = TerminalController.findAppBundleId(for: 100, env: env)
        #expect(bundleId == "com.apple.Terminal")
    }

    @Test("Fallback prefers Terminal over iTerm if both running")
    func fallbackPrefersTerminal() {
        let env = MockSystemEnvironment()
        env.parentPids = [100: 0]
        env.runningApps = ["com.apple.Terminal", "com.googlecode.iterm2"]

        let bundleId = TerminalController.findAppBundleId(for: 100, env: env)
        #expect(bundleId == "com.apple.Terminal")
    }

    @Test("Returns nil when no terminal app found and tree walk fails")
    func returnsNilWhenNoApp() {
        let env = MockSystemEnvironment()
        env.parentPids = [100: 0]
        env.runningApps = ["com.spotify.client"]

        let bundleId = TerminalController.findAppBundleId(for: 100, env: env)
        #expect(bundleId == nil)
    }

    @Test("Handles deep process tree")
    func deepProcessTree() {
        let env = MockSystemEnvironment()
        env.parentPids = [100: 101, 101: 102, 102: 103, 103: 104]
        env.guiApps = [104: "com.apple.Terminal"]

        let bundleId = TerminalController.findAppBundleId(for: 100, env: env)
        #expect(bundleId == "com.apple.Terminal")
    }

    @Test("Stops at max depth to avoid infinite loops")
    func maxDepthSafety() {
        let env = MockSystemEnvironment()
        for i in 100..<115 {
            env.parentPids[pid_t(i)] = pid_t(i + 1)
        }
        env.guiApps = [115: "com.apple.Terminal"]
        env.runningApps = []

        let bundleId = TerminalController.findAppBundleId(for: 100, env: env)
        #expect(bundleId == nil)
    }

    @Test("PID that is itself a GUI app")
    func pidIsGuiApp() {
        let env = MockSystemEnvironment()
        env.guiApps = [100: "com.apple.Terminal"]

        let bundleId = TerminalController.findAppBundleId(for: 100, env: env)
        #expect(bundleId == "com.apple.Terminal")
    }
}

// MARK: - Script Generation Tests

@Suite("TerminalController - Script Generation")
struct ScriptGenerationTests {
    @Test("Terminal.app script matches by TTY")
    func terminalScript() {
        let script = TerminalController.buildFocusScript(
            app: .terminal,
            appName: "Terminal",
            tty: "/dev/ttys042",
            directory: "/Users/me/projects/cool-app"
        )

        #expect(script != nil)
        #expect(script!.contains("tell application \"Terminal\""))
        #expect(script!.contains("tty of t is \"/dev/ttys042\""))
        #expect(script!.contains("set selected of t to true"))
        #expect(script!.contains("set index of w to 1"))
    }

    @Test("Terminal.app returns nil without TTY")
    func terminalScriptNoTty() {
        let script = TerminalController.buildFocusScript(
            app: .terminal,
            appName: "Terminal",
            tty: nil,
            directory: "/Users/me/project"
        )
        #expect(script == nil)
    }

    @Test("iTerm2 script matches by TTY")
    func itermScript() {
        let script = TerminalController.buildFocusScript(
            app: .iterm2,
            appName: "iTerm2",
            tty: "/dev/ttys007",
            directory: "/Users/me/project"
        )

        #expect(script != nil)
        #expect(script!.contains("tell application \"iTerm2\""))
        #expect(script!.contains("tty of s is \"/dev/ttys007\""))
        #expect(script!.contains("select s"))
        #expect(script!.contains("select w"))
    }

    @Test("iTerm2 returns nil without TTY")
    func itermScriptNoTty() {
        let script = TerminalController.buildFocusScript(
            app: .iterm2,
            appName: "iTerm2",
            tty: nil,
            directory: "/Users/me/project"
        )
        #expect(script == nil)
    }

    @Test("Ghostty script matches by TTY before working directory")
    func ghosttyScript() {
        let script = TerminalController.buildFocusScript(
            app: .ghostty,
            appName: "Ghostty",
            tty: "/dev/ttys042",
            directory: "/Users/me/projects/cool-app"
        )

        #expect(script != nil)
        #expect(script!.contains("tell application \"Ghostty\""))
        #expect(script!.contains("tty of trm is \"/dev/ttys042\""))
        #expect(script!.contains("working directory of trm is \"/Users/me/projects/cool-app\""))
        // TTY is unique per surface; directory is ambiguous when several
        // surfaces share a cwd. TTY must be tried first.
        let ttyMatch = script!.range(of: "tty of trm is")!
        let dirMatch = script!.range(of: "working directory of trm is")!
        #expect(ttyMatch.lowerBound < dirMatch.lowerBound)
        // Directory fallback keeps its selected-tab-first ordering
        let selectedTabCheck = script!.range(of: "selected tab of front window")!
        let fullScan = script!.range(of: "select tab t")!
        #expect(selectedTabCheck.lowerBound < fullScan.lowerBound)
    }

    @Test("Ghostty TTY match uses `focus` so it resolves splits, not just tabs")
    func ghosttyScriptTtyFocusesSurface() {
        let script = TerminalController.buildFocusScript(
            app: .ghostty,
            appName: "Ghostty",
            tty: "/dev/ttys042",
            directory: "/Users/me/project"
        )

        #expect(script != nil)
        // `focus` targets the surface — raises the window, selects the tab AND
        // focuses the split. `select tab` alone leaves focus in the wrong pane.
        let ttyMatch = script!.range(of: "tty of trm is")!
        let focusCall = script!.range(of: "focus trm")!
        #expect(ttyMatch.upperBound < focusCall.lowerBound)
        // The flat application-level `terminals` element covers every split
        // without walking windows -> tabs -> terminals.
        #expect(script!.contains("repeat with trm in terminals\n"))
    }

    @Test("Ghostty precision rungs are wrapped in try so older versions degrade")
    func ghosttyScriptTtyIsVersionGuarded() {
        let script = TerminalController.buildFocusScript(
            app: .ghostty,
            appName: "Ghostty",
            tty: "/dev/ttys042",
            directory: "/Users/me/project",
            windowId: "F63A60A0-F28D-4FDC-8666-5844F57BDC1D"
        )

        #expect(script != nil)
        // `tty` and `focus` are absent from older Ghostty dictionaries. Without
        // `try`, the unknown term aborts the whole script and takes the
        // directory fallback down with it.
        #expect(script!.contains("try\n"))
        #expect(script!.contains("end try"))
        // Both precision rungs are guarded, and the directory fallback survives.
        #expect(script!.components(separatedBy: "end try").count - 1 == 2)
        #expect(script!.contains("working directory of trm is \"/Users/me/project\""))
    }

    @Test("Ghostty script escapes the TTY path")
    func ghosttyScriptEscapesTty() {
        let script = TerminalController.buildFocusScript(
            app: .ghostty,
            appName: "Ghostty",
            tty: "/dev/tty\"; do shell script \"whoami",
            directory: "/Users/me/project"
        )

        #expect(script != nil)
        #expect(!script!.contains("tty of trm is \"/dev/tty\"; do shell script"))
        #expect(script!.contains("\\\""))
    }

    @Test("Ghostty script works without TTY (uses directory instead)")
    func ghosttyScriptNoTty() {
        let script = TerminalController.buildFocusScript(
            app: .ghostty,
            appName: "Ghostty",
            tty: nil,
            directory: "/Users/me/project"
        )

        #expect(script != nil)
        #expect(script!.contains("working directory of trm is \"/Users/me/project\""))
    }

    @Test("Ghostty ladder is TTY, then legacy terminal ID, then directory")
    func ghosttyScriptWithTerminalId() {
        let script = TerminalController.buildFocusScript(
            app: .ghostty,
            appName: "Ghostty",
            tty: "/dev/ttys042",
            directory: "/Users/me/projects/cool-app",
            windowId: "F63A60A0-F28D-4FDC-8666-5844F57BDC1D"
        )

        #expect(script != nil)
        #expect(script!.contains("tell application \"Ghostty\""))
        #expect(script!.contains("id of trm is \"F63A60A0-F28D-4FDC-8666-5844F57BDC1D\""))
        // Must also include directory fallback (ID may be stale after resume)
        #expect(script!.contains("working directory"))
        // TTY beats the stored ID: the ID is only there for rows written by the
        // pre-TTY hook, and it goes stale on resume. Directory is last.
        let ttyMatch = script!.range(of: "tty of trm is")!
        let idMatch = script!.range(of: "id of trm is")!
        let dirMatch = script!.range(of: "working directory")!
        #expect(ttyMatch.lowerBound < idMatch.lowerBound)
        #expect(idMatch.lowerBound < dirMatch.lowerBound)
    }

    @Test("Ghostty legacy ID rung is omitted when no windowId is stored")
    func ghosttyScriptWithoutTerminalId() {
        let script = TerminalController.buildFocusScript(
            app: .ghostty,
            appName: "Ghostty",
            tty: "/dev/ttys042",
            directory: "/Users/me/project"
        )

        #expect(script != nil)
        #expect(!script!.contains("id of trm is"))
        #expect(script!.contains("tty of trm is \"/dev/ttys042\""))
    }

    @Test("Warp focus script uses TTY-based tab position via pgrep/ps")
    func warpScript() {
        let script = TerminalController.buildFocusScript(
            app: .warp,
            appName: "Warp",
            tty: "/dev/ttys007",
            directory: "/Users/me/projects/cool-app"
        )

        #expect(script != nil)
        #expect(script!.contains("ttys007"))
        #expect(script!.contains("pgrep"))
        #expect(script!.contains("keystroke"))
        #expect(script!.contains("using command down"))
        #expect(script!.contains("\"System Events\""))
        #expect(script!.contains("quoted form of ttyName"))
    }

    @Test("Warp focus script falls back to window name matching when no TTY")
    func warpScriptFallback() {
        let script = TerminalController.buildFocusScript(
            app: .warp,
            appName: "Warp",
            tty: nil,
            directory: "/Users/me/projects/cool-app"
        )

        #expect(script != nil)
        #expect(script!.contains("name of w contains \"cool-app\""))
        #expect(!script!.contains("pgrep"))
    }

    @Test("cmux focus script matches by workspace UUID via id of tab (no surface → backward-compat, no focus)")
    func cmuxFocusScript() {
        let script = TerminalController.buildFocusScript(
            app: .cmux,
            appName: "cmux",
            tty: nil,
            directory: "/Users/me/projects/cool-app",
            windowId: "F63A60A0-F28D-4FDC-8666-5844F57BDC1D"
        )

        #expect(script != nil)
        #expect(script!.contains("tell application \"cmux\""))
        #expect(script!.contains("id of t is \"F63A60A0-F28D-4FDC-8666-5844F57BDC1D\""))
        #expect(script!.contains("select tab t"))
        #expect(script!.contains("activate window w"))
        #expect(script!.contains("repeat with t in tabs of w"))
        // Backward-compat path (no pipe in windowId): no terminal-level focus emitted.
        #expect(!script!.contains("focus tr"))
        #expect(!script!.contains("terminals of t"))
    }

    @Test("cmux focus script with workspace|surface packs both IDs and emits nested focus")
    func cmuxFocusScriptWithSurface() {
        let script = TerminalController.buildFocusScript(
            app: .cmux,
            appName: "cmux",
            tty: nil,
            directory: "/Users/me/projects/cool-app",
            windowId: "B6A46C7F-B8D8-40C3-8FB5-9647058B0865|74DAD70B-584E-4ECB-9095-0A1C3649F120"
        )

        #expect(script != nil)
        let s = script!
        // Workspace-level match uses just the left side of the pipe.
        #expect(s.contains("id of t is \"B6A46C7F-B8D8-40C3-8FB5-9647058B0865\""))
        #expect(!s.contains("id of t is \"B6A46C7F-B8D8-40C3-8FB5-9647058B0865|74DAD70B-584E-4ECB-9095-0A1C3649F120\""))
        // Surface-level match uses the right side and calls `focus tr`.
        #expect(s.contains("repeat with tr in terminals of t"))
        #expect(s.contains("id of tr is \"74DAD70B-584E-4ECB-9095-0A1C3649F120\""))
        #expect(s.contains("focus tr"))
        // Workspace check must precede surface check so the outer repeat drills
        // into the right tab before iterating its terminals.
        let workspaceRange = s.range(of: "id of t is \"B6A46C7F")!
        let surfaceRange = s.range(of: "id of tr is \"74DAD70B")!
        #expect(workspaceRange.lowerBound < surfaceRange.lowerBound)
    }

    @Test("cmux focus script with empty surface part (trailing pipe) falls back to workspace-only")
    func cmuxFocusScriptEmptySurface() {
        let script = TerminalController.buildFocusScript(
            app: .cmux,
            appName: "cmux",
            tty: nil,
            directory: "/Users/me/projects/cool-app",
            windowId: "B6A46C7F-B8D8-40C3-8FB5-9647058B0865|"
        )

        #expect(script != nil)
        let s = script!
        // Workspace still selected, but no inner focus block.
        #expect(s.contains("id of t is \"B6A46C7F-B8D8-40C3-8FB5-9647058B0865\""))
        #expect(s.contains("select tab t"))
        #expect(!s.contains("focus tr"))
        #expect(!s.contains("terminals of t"))
    }

    @Test("cmux focus script returns nil without windowId")
    func cmuxFocusScriptNoWindowId() {
        let script = TerminalController.buildFocusScript(
            app: .cmux,
            appName: "cmux",
            tty: nil,
            directory: "/Users/me/project",
            windowId: nil
        )
        #expect(script == nil)
    }

    @Test("cmux focus script escapes AppleScript special characters in windowId")
    func cmuxFocusScriptEscaping() {
        // UUIDs shouldn't contain backslashes/quotes, but the escaping path
        // must be robust against anything stored in the DB.
        let script = TerminalController.buildFocusScript(
            app: .cmux,
            appName: "cmux",
            tty: nil,
            directory: "/tmp",
            windowId: "evil\"\\id"
        )
        #expect(script != nil)
        // Quote and backslash must both be escaped for the AppleScript string literal.
        #expect(script!.contains("id of t is \"evil\\\"\\\\id\""))
    }

    @Test("cmux focus script escapes AppleScript special characters in surface UUID too")
    func cmuxFocusScriptSurfaceEscaping() {
        // Mirror the workspace-id escape test but for the surface half. The
        // surface part also flows through escapeForAppleScript before
        // interpolation, so quotes and backslashes must be doubled.
        let script = TerminalController.buildFocusScript(
            app: .cmux,
            appName: "cmux",
            tty: nil,
            directory: "/tmp",
            windowId: "B6A46C7F-B8D8-40C3-8FB5-9647058B0865|evil\"\\surface"
        )
        #expect(script != nil)
        let s = script!
        #expect(s.contains("id of t is \"B6A46C7F-B8D8-40C3-8FB5-9647058B0865\""))
        #expect(s.contains("id of tr is \"evil\\\"\\\\surface\""))
    }

    @Test("VS Code falls through to generic script in buildFocusScript (handled separately via focusVSCode)")
    func vscodeFallsToGeneric() {
        let script = TerminalController.buildFocusScript(
            app: .vscode,
            appName: "Code",
            tty: "/dev/ttys001",
            directory: "/Users/me/projects/seshctl"
        )

        // VS Code is handled separately by focusVSCode(), so buildFocusScript
        // returns the generic System Events script as fallback.
        #expect(script != nil)
        #expect(script!.contains("tell process \"Code\""))
        #expect(script!.contains("seshctl"))
    }

    @Test("Unknown app uses generic System Events script")
    func unknownAppScript() {
        let script = TerminalController.buildFocusScript(
            app: nil,
            appName: "SomeTerminal",
            tty: nil,
            directory: "/Users/me/project"
        )

        #expect(script != nil)
        #expect(script!.contains("tell process \"SomeTerminal\""))
        #expect(script!.contains("name of w contains \"project\""))
    }

    @Test("Directory name is extracted from full path (generic app)")
    func directoryNameExtraction() {
        let script = TerminalController.buildFocusScript(
            app: nil,
            appName: "SomeApp",
            tty: nil,
            directory: "/Users/me/deeply/nested/my-project"
        )

        #expect(script != nil)
        #expect(script!.contains("name of w contains \"my-project\""))
    }

    @Test("Special characters in directory name are escaped (generic app)")
    func specialCharsEscaped() {
        let script = TerminalController.buildFocusScript(
            app: nil,
            appName: "SomeApp",
            tty: nil,
            directory: "/Users/me/project with \"quotes\""
        )

        #expect(script != nil)
        #expect(script!.contains("project with \\\"quotes\\\""))
    }

    @Test("Special characters in TTY are escaped")
    func ttyEscaped() {
        // TTYs shouldn't have special chars, but verify escaping works
        let script = TerminalController.buildFocusScript(
            app: .terminal,
            appName: "Terminal",
            tty: "/dev/ttys000",
            directory: "/tmp"
        )

        #expect(script != nil)
        #expect(script!.contains("/dev/ttys000"))
    }
}

// MARK: - AppleScript Escaping Tests

@Suite("TerminalController - Escaping")
struct EscapingTests {
    @Test("Escapes backslashes")
    func escapesBackslashes() {
        #expect(TerminalController.escapeForAppleScript("a\\b") == "a\\\\b")
    }

    @Test("Escapes double quotes")
    func escapesQuotes() {
        #expect(TerminalController.escapeForAppleScript("say \"hi\"") == "say \\\"hi\\\"")
    }

    @Test("Leaves normal strings unchanged")
    func normalStrings() {
        #expect(TerminalController.escapeForAppleScript("hello world") == "hello world")
    }

    @Test("Handles empty string")
    func emptyString() {
        #expect(TerminalController.escapeForAppleScript("") == "")
    }

    @Test("Handles mixed special characters")
    func mixedSpecials() {
        let result = TerminalController.escapeForAppleScript("path\\to\\\"file\"")
        #expect(result == "path\\\\to\\\\\\\"file\\\"")
    }

    @Test("Strips newlines to prevent AppleScript injection")
    func stripsNewlines() {
        let malicious = "test\nend tell\ntell application \"Evil\""
        let result = TerminalController.escapeForAppleScript(malicious)
        // Newlines stripped — injection can't break out of string literal
        #expect(!result.contains("\n"))
        // Quotes are escaped — can't close the string literal
        #expect(!result.contains("\"Evil\""))
        #expect(result.contains("\\\"Evil\\\""))
    }

    @Test("Strips carriage returns")
    func stripsCarriageReturns() {
        let result = TerminalController.escapeForAppleScript("line1\r\nline2")
        #expect(!result.contains("\r"))
        #expect(!result.contains("\n"))
    }

    @Test("Replaces tabs with spaces")
    func replacesTabsWithSpaces() {
        let result = TerminalController.escapeForAppleScript("col1\tcol2")
        #expect(result == "col1 col2")
    }

    @Test("Strips null bytes and other control characters")
    func stripsControlChars() {
        let result = TerminalController.escapeForAppleScript("ab\0cd\u{07}ef")
        #expect(result == "abcdef")
    }

    @Test("Preserves unicode and emoji in directory names")
    func preservesUnicode() {
        let result = TerminalController.escapeForAppleScript("projet-été-🚀")
        #expect(result == "projet-été-🚀")
    }
}

// MARK: - Focus Routing Tests

@Suite("TerminalController - Focus Routing", .serialized)
struct FocusRoutingTests {
    @Test("Terminal.app focus uses open -b then AppleScript")
    func terminalRouting() {
        let env = MockSystemEnvironment()
        env.guiApps = [100: "com.apple.Terminal"]
        env.ttys = [100: "/dev/ttys001"]

        TerminalController.focus(pid: 100, directory: "/tmp/project", launchDirectory: nil, environment: env)

        // open -b should be called to activate the app
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.apple.Terminal"] })
        // AppleScript should select the right tab
        #expect(env.executedScripts.count >= 1)
        #expect(env.executedScripts[0].contains("tty of t is \"/dev/ttys001\""))
        // Should NOT use activateApp fallback
        #expect(env.activatedApps.isEmpty)
    }

    @Test("iTerm2 focus uses open -b then AppleScript")
    func itermRouting() {
        let env = MockSystemEnvironment()
        env.guiApps = [200: "com.googlecode.iterm2"]
        env.ttys = [200: "/dev/ttys005"]

        TerminalController.focus(pid: 200, directory: "/tmp/project", launchDirectory: nil, environment: env)

        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.googlecode.iterm2"] })
        #expect(env.executedScripts.count >= 1)
        #expect(env.executedScripts[0].contains("tty of s is \"/dev/ttys005\""))
    }

    @Test("VS Code focus uses open -b with launchDirectory then URI handler")
    func vscodeRouting() {
        let env = MockSystemEnvironment()
        env.guiApps = [300: "com.microsoft.VSCode"]

        TerminalController.focus(
            pid: 300,
            directory: "/tmp/worktree",
            launchDirectory: "/tmp/launch",
            environment: env
        )

        // open -b should use launchDirectory (not the worktree directory)
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.microsoft.VSCode", "/tmp/launch"] })
        // URI handler for terminal tab focus
        #expect(env.shellCommands.contains { $0.1.first?.starts(with: "vscode://") == true })
        // No shell command should reference the worktree directory
        #expect(!env.shellCommands.contains { $0.1.contains("/tmp/worktree") })
        // Should NOT use AppleScript
        #expect(env.executedScripts.isEmpty)
    }

    @Test("Cursor focus uses cursor:// URI scheme")
    func cursorRouting() {
        let env = MockSystemEnvironment()
        env.guiApps = [500: "com.todesktop.230313mzl4w4u92"]

        TerminalController.focus(
            pid: 500,
            directory: "/tmp/worktree",
            launchDirectory: "/tmp/launch",
            environment: env
        )

        // open -b should use launchDirectory (not the worktree directory)
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.todesktop.230313mzl4w4u92", "/tmp/launch"] })
        // URI handler should use cursor:// scheme, not vscode://
        #expect(env.shellCommands.contains { $0.1.first?.starts(with: "cursor://") == true })
        // No shell command should reference the worktree directory
        #expect(!env.shellCommands.contains { $0.1.contains("/tmp/worktree") })
        // Should NOT use AppleScript
        #expect(env.executedScripts.isEmpty)
    }

    @Test("Cursor chat session focus uses /focus-chat URI with composerId")
    func cursorChatFocusUsesComposerURI() {
        let env = MockSystemEnvironment()
        env.guiApps = [500: "com.todesktop.230313mzl4w4u92"]

        TerminalController.focus(
            pid: 500,
            directory: "/tmp/seshctl",
            launchDirectory: nil,
            hostWorkspaceFolder: nil,
            bundleId: "com.todesktop.230313mzl4w4u92",
            windowId: nil,
            tool: .cursor,
            conversationId: "71836c6c-58b9-4081-bd3e-b6a953b2378c",
            environment: env
        )

        // open -b first (workspace focus leg)
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.todesktop.230313mzl4w4u92", "/tmp/seshctl"] })
        // URI route must be /focus-chat with id, not /focus-terminal
        #expect(env.shellCommands.contains { $0.1.first?.contains("/focus-chat?id=71836c6c-58b9-4081-bd3e-b6a953b2378c") == true })
        #expect(!env.shellCommands.contains { $0.1.first?.contains("/focus-terminal") == true })
    }

    @Test("Cursor focus with nil conversationId falls back to /focus-terminal")
    func cursorChatFocusFallsBackWhenConversationIdMissing() {
        let env = MockSystemEnvironment()
        env.guiApps = [500: "com.todesktop.230313mzl4w4u92"]

        TerminalController.focus(
            pid: 500,
            directory: "/tmp/seshctl",
            launchDirectory: nil,
            hostWorkspaceFolder: nil,
            bundleId: "com.todesktop.230313mzl4w4u92",
            windowId: nil,
            tool: .cursor,
            conversationId: nil,
            environment: env
        )

        // Should NOT route to /focus-chat — a Cursor session without a
        // conversationId should still get workspace-level focus via the
        // standard terminal-PID URI rather than break entirely.
        #expect(!env.shellCommands.contains { $0.1.first?.contains("/focus-chat") == true })
        #expect(env.shellCommands.contains { $0.1.first?.contains("/focus-terminal?pid=500") == true })
    }

    @Test("Cursor focus with empty conversationId falls back to /focus-terminal")
    func cursorChatFocusFallsBackWhenConversationIdEmpty() {
        let env = MockSystemEnvironment()
        env.guiApps = [500: "com.todesktop.230313mzl4w4u92"]

        TerminalController.focus(
            pid: 500,
            directory: "/tmp/seshctl",
            launchDirectory: nil,
            hostWorkspaceFolder: nil,
            bundleId: "com.todesktop.230313mzl4w4u92",
            windowId: nil,
            tool: .cursor,
            conversationId: "",
            environment: env
        )

        #expect(!env.shellCommands.contains { $0.1.first?.contains("/focus-chat") == true })
        #expect(env.shellCommands.contains { $0.1.first?.contains("/focus-terminal?pid=500") == true })
    }

    @Test("Cursor focus falls back to directory when launchDirectory is nil")
    func cursorFocusFallsBackToDirectoryWhenLaunchDirMissing() {
        let env = MockSystemEnvironment()
        env.guiApps = [500: "com.todesktop.230313mzl4w4u92"]

        TerminalController.focus(
            pid: 500,
            directory: "/tmp/project",
            launchDirectory: nil,
            environment: env
        )

        // When launchDirectory is nil, open -b falls back to directory
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.todesktop.230313mzl4w4u92", "/tmp/project"] })
        // URI handler still fires, using cursor:// scheme
        #expect(env.shellCommands.contains { $0.1.first?.starts(with: "cursor://") == true })
        // Should NOT use AppleScript
        #expect(env.executedScripts.isEmpty)
    }

    @Test("Cursor focus prefers hostWorkspaceFolder over launchDirectory")
    func cursorFocusPrefersHostWorkspaceFolder() {
        let env = MockSystemEnvironment()
        env.guiApps = [500: "com.todesktop.230313mzl4w4u92"]

        TerminalController.focus(
            pid: 500,
            directory: "/tmp/worktree",
            launchDirectory: "/tmp/launch",
            hostWorkspaceFolder: "/tmp/host-workspace",
            environment: env
        )

        // open -b should use hostWorkspaceFolder (not launchDirectory or worktree)
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.todesktop.230313mzl4w4u92", "/tmp/host-workspace"] })
        #expect(!env.shellCommands.contains { $0.1.contains("/tmp/launch") })
        #expect(!env.shellCommands.contains { $0.1.contains("/tmp/worktree") })
        // URI handler still fires, using cursor:// scheme
        #expect(env.shellCommands.contains { $0.1.first?.starts(with: "cursor://") == true })
    }

    @Test("Cursor focus treats empty hostWorkspaceFolder as nil and falls back to launchDirectory")
    func cursorFocusEmptyHostWorkspaceFolderFallsBack() {
        let env = MockSystemEnvironment()
        env.guiApps = [500: "com.todesktop.230313mzl4w4u92"]

        TerminalController.focus(
            pid: 500,
            directory: "/tmp/worktree",
            launchDirectory: "/tmp/launch",
            hostWorkspaceFolder: "",
            environment: env
        )

        // Empty hostWorkspaceFolder should be ignored; falls back to launchDirectory
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.todesktop.230313mzl4w4u92", "/tmp/launch"] })
        #expect(!env.shellCommands.contains { $0.1.contains("/tmp/worktree") })
    }

    @Test("VS Code focus falls back to directory when launchDirectory is nil")
    func vscodeFocusFallsBackToDirectoryWhenLaunchDirMissing() {
        let env = MockSystemEnvironment()
        env.guiApps = [300: "com.microsoft.VSCode"]

        TerminalController.focus(
            pid: 300,
            directory: "/tmp/project",
            launchDirectory: nil,
            environment: env
        )

        // When launchDirectory is nil, open -b falls back to directory
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.microsoft.VSCode", "/tmp/project"] })
        // URI handler still fires
        #expect(env.shellCommands.contains { $0.1.first?.starts(with: "vscode://") == true })
        // Should NOT use AppleScript
        #expect(env.executedScripts.isEmpty)
    }

    @Test("VS Code focus prefers hostWorkspaceFolder over launchDirectory")
    func vscodeFocusPrefersHostWorkspaceFolder() {
        let env = MockSystemEnvironment()
        env.guiApps = [300: "com.microsoft.VSCode"]

        TerminalController.focus(
            pid: 300,
            directory: "/tmp/worktree",
            launchDirectory: "/tmp/launch",
            hostWorkspaceFolder: "/tmp/host-workspace",
            environment: env
        )

        // open -b should use hostWorkspaceFolder (not launchDirectory or worktree)
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.microsoft.VSCode", "/tmp/host-workspace"] })
        #expect(!env.shellCommands.contains { $0.1.contains("/tmp/launch") })
        #expect(!env.shellCommands.contains { $0.1.contains("/tmp/worktree") })
        // URI handler still fires
        #expect(env.shellCommands.contains { $0.1.first?.starts(with: "vscode://") == true })
    }

    @Test("VS Code focus treats empty hostWorkspaceFolder as nil and falls back to launchDirectory")
    func vscodeFocusEmptyHostWorkspaceFolderFallsBack() {
        let env = MockSystemEnvironment()
        env.guiApps = [300: "com.microsoft.VSCode"]

        TerminalController.focus(
            pid: 300,
            directory: "/tmp/worktree",
            launchDirectory: "/tmp/launch",
            hostWorkspaceFolder: "",
            environment: env
        )

        // Empty hostWorkspaceFolder should be ignored; falls back to launchDirectory
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.microsoft.VSCode", "/tmp/launch"] })
        #expect(!env.shellCommands.contains { $0.1.contains("/tmp/worktree") })
    }

    @Test("Ghostty focus uses open -b then AppleScript with TTY matching")
    func ghosttyRouting() {
        let env = MockSystemEnvironment()
        env.guiApps = [600: "com.mitchellh.ghostty"]
        env.ttys = [600: "/dev/ttys010"]

        TerminalController.focus(pid: 600, directory: "/tmp/project", launchDirectory: nil, environment: env)

        // open -b should be called to activate the app
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.mitchellh.ghostty"] })
        // TTY is resolved from the session PID at focus time — nothing needs to
        // have been recorded at session start.
        #expect(env.executedScripts.count >= 1)
        #expect(env.executedScripts[0].contains("tty of trm is \"/dev/ttys010\""))
        #expect(env.executedScripts[0].contains("working directory of trm is \"/tmp/project\""))
    }

    @Test("Ghostty focus falls back to directory when the PID has no TTY")
    func ghosttyRoutingNoTty() {
        let env = MockSystemEnvironment()
        env.guiApps = [600: "com.mitchellh.ghostty"]

        TerminalController.focus(pid: 600, directory: "/tmp/project", launchDirectory: nil, environment: env)

        #expect(env.executedScripts.count >= 1)
        #expect(!env.executedScripts[0].contains("tty of trm is"))
        #expect(env.executedScripts[0].contains("working directory of trm is \"/tmp/project\""))
    }

    @Test("Ghostty focus with windowId keeps the legacy ID rung below TTY")
    func ghosttyRoutingWithWindowId() {
        let env = MockSystemEnvironment()
        env.guiApps = [600: "com.mitchellh.ghostty"]
        env.ttys = [600: "/dev/ttys010"]

        TerminalController.focus(
            pid: 600,
            directory: "/tmp/project",
            launchDirectory: nil,
            bundleId: "com.mitchellh.ghostty",
            windowId: "F63A60A0-F28D-4FDC-8666-5844F57BDC1D",
            environment: env
        )

        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.mitchellh.ghostty"] })
        #expect(env.executedScripts.count >= 1)
        let script = env.executedScripts[0]
        #expect(script.contains("id of trm is \"F63A60A0-F28D-4FDC-8666-5844F57BDC1D\""))
        // Script should also contain directory fallback (ID may be stale)
        #expect(script.contains("working directory"))
        #expect(script.range(of: "tty of trm is")!.lowerBound < script.range(of: "id of trm is")!.lowerBound)
    }

    @Test("Warp focus uses open -b then AppleScript with TTY-based tab lookup")
    func warpRouting() {
        let env = MockSystemEnvironment()
        env.guiApps = [700: "dev.warp.Warp-Stable"]
        env.ttys = [700: "/dev/ttys003"]

        TerminalController.focus(pid: 700, directory: "/tmp/project", launchDirectory: nil, environment: env)

        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "dev.warp.Warp-Stable"] })
        #expect(env.executedScripts.count >= 1)
        #expect(env.executedScripts[0].contains("pgrep"))
        #expect(env.executedScripts[0].contains("ttys003"))
    }

    @Test("cmux focus uses open -b then AppleScript matching the stored workspace UUID")
    func cmuxRouting() {
        let env = MockSystemEnvironment()
        env.guiApps = [999: "com.cmuxterm.app"]

        TerminalController.focus(
            pid: 999,
            directory: "/tmp/project",
            launchDirectory: nil,
            bundleId: "com.cmuxterm.app",
            windowId: "F63A60A0-F28D-4FDC-8666-5844F57BDC1D",
            environment: env
        )

        // open -b should be called to activate the app
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.cmuxterm.app"] })
        // AppleScript path must fire with the cmux-specific script
        #expect(env.executedScripts.count >= 1)
        #expect(env.executedScripts[0].contains("tell application \"cmux\""))
        #expect(env.executedScripts[0].contains("id of t is \"F63A60A0-F28D-4FDC-8666-5844F57BDC1D\""))
        // URI and activateApp paths must NOT fire
        #expect(env.openedURLs.isEmpty)
        #expect(env.activatedApps.isEmpty)
    }

    @Test("Unknown app uses generic AppleScript path")
    func unknownAppRouting() {
        let env = MockSystemEnvironment()
        env.guiApps = [400: "com.example.SomeApp"]
        env.appNames = [400: "SomeApp"]

        TerminalController.focus(pid: 400, directory: "/tmp/my-project", launchDirectory: nil, environment: env)

        // Should NOT use open -b
        #expect(env.shellCommands.isEmpty)
        // Should use generic System Events script
        #expect(env.executedScripts.count == 1)
        #expect(env.executedScripts[0].contains("tell process \"SomeApp\""))
        #expect(env.executedScripts[0].contains("my-project"))
    }
}

// MARK: - Resume Command Tests

@Suite("TerminalController - buildResumeCommand")
struct BuildResumeCommandTests {

    private func makeSession(
        tool: SessionTool = .claude,
        conversationId: String? = "abc-123",
        launchArgs: String? = nil,
        hostAppBundleId: String? = nil,
        pid: Int? = 12345
    ) -> Session {
        Session(
            id: UUID().uuidString,
            conversationId: conversationId,
            tool: tool,
            directory: "/tmp/project",
            launchDirectory: nil,
            hostWorkspaceFolder: nil,
            lastAsk: nil,
            lastReply: nil,
            status: .idle,
            pid: pid,
            hostAppBundleId: hostAppBundleId,
            hostAppName: nil,
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

    @Test("Claude with launchArgs and conversationId")
    func claudeWithArgs() {
        let session = makeSession(
            tool: .claude,
            conversationId: "abc-123",
            launchArgs: "--dangerously-skip-permissions"
        )
        let command = TerminalController.buildResumeCommand(session: session)
        #expect(command == "claude --dangerously-skip-permissions --resume abc-123")
    }

    @Test("Codex with launchArgs and conversationId")
    func codexWithArgs() {
        let session = makeSession(
            tool: .codex,
            conversationId: "def-456",
            launchArgs: "--full-auto"
        )
        let command = TerminalController.buildResumeCommand(session: session)
        #expect(command == "codex --full-auto resume def-456")
    }

    @Test("Gemini with no launchArgs")
    func geminiNoArgs() {
        let session = makeSession(
            tool: .gemini,
            conversationId: "ghi-789",
            launchArgs: nil
        )
        let command = TerminalController.buildResumeCommand(session: session)
        #expect(command == "gemini --resume ghi-789")
    }

    @Test("Empty string launchArgs produces no extra space")
    func emptyLaunchArgs() {
        let session = makeSession(
            tool: .claude,
            conversationId: "abc-123",
            launchArgs: ""
        )
        let command = TerminalController.buildResumeCommand(session: session)
        #expect(command == "claude --resume abc-123")
    }

    @Test("Nil conversationId returns nil")
    func nilConversationId() {
        let session = makeSession(
            tool: .claude,
            conversationId: nil
        )
        let command = TerminalController.buildResumeCommand(session: session)
        #expect(command == nil)
    }

    @Test("Sanitizes --session-id and --settings out of launchArgs")
    func sanitizesUnshellableFlags() {
        let session = makeSession(
            tool: .claude,
            conversationId: "abc-123",
            launchArgs: "--session-id 845ea4dd-6868-4cfa-b73b-5a6299285842 --settings {\"a\":1} --dangerously-skip-permissions"
        )
        let command = TerminalController.buildResumeCommand(session: session)
        #expect(command == "claude --dangerously-skip-permissions --resume abc-123")
    }
}

// MARK: - Fork Command Tests

@Suite("TerminalController - buildForkCommand")
struct BuildForkCommandTests {

    private func makeSession(
        tool: SessionTool = .claude,
        conversationId: String? = "abc-123",
        launchArgs: String? = nil
    ) -> Session {
        Session(
            id: UUID().uuidString,
            conversationId: conversationId,
            tool: tool,
            directory: "/tmp/project",
            launchDirectory: nil,
            hostWorkspaceFolder: nil,
            lastAsk: nil,
            lastReply: nil,
            status: .idle,
            pid: 12345,
            hostAppBundleId: nil,
            hostAppName: nil,
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

    @Test("Claude session with conversationId returns resume command with --fork-session appended")
    func claudeWithConversationId() {
        let session = makeSession(tool: .claude, conversationId: "abc-123")
        let command = TerminalController.buildForkCommand(session: session)
        #expect(command == "claude --resume abc-123 --fork-session")
    }

    @Test("Claude session without conversationId returns nil")
    func claudeMissingConversationId() {
        let session = makeSession(tool: .claude, conversationId: nil)
        let command = TerminalController.buildForkCommand(session: session)
        #expect(command == nil)
    }

    @Test("Gemini session returns nil even with conversationId")
    func geminiReturnsNil() {
        let session = makeSession(tool: .gemini, conversationId: "ghi-789")
        let command = TerminalController.buildForkCommand(session: session)
        #expect(command == nil)
    }

    @Test("Codex session returns nil even with conversationId")
    func codexReturnsNil() {
        let session = makeSession(tool: .codex, conversationId: "def-456")
        let command = TerminalController.buildForkCommand(session: session)
        #expect(command == nil)
    }

    @Test("Claude session preserves launchArgs in fork command")
    func claudePreservesLaunchArgs() {
        let session = makeSession(
            tool: .claude,
            conversationId: "abc-123",
            launchArgs: "--dangerously-skip-permissions"
        )
        let command = TerminalController.buildForkCommand(session: session)
        #expect(command == "claude --dangerously-skip-permissions --resume abc-123 --fork-session")
    }

    @Test("Sanitizes --session-id and --settings out of fork launchArgs")
    func sanitizesUnshellableFlagsInFork() {
        let session = makeSession(
            tool: .claude,
            conversationId: "abc-123",
            launchArgs: "--session-id 845ea4dd-6868-4cfa-b73b-5a6299285842 --settings {\"a\":1} --dangerously-skip-permissions"
        )
        let command = TerminalController.buildForkCommand(session: session)
        #expect(command == "claude --dangerously-skip-permissions --resume abc-123 --fork-session")
    }
}

// MARK: - Fork Routing Tests

@Suite("TerminalController - fork routing", .serialized)
struct ForkRoutingTests {

    private static let cmuxBundleId = "com.cmuxterm.app"
    private static let cmuxBundlePath = "/tmp/seshctl-test-fixture/cmux.app"
    private static let workspaceId = "AAAAAAAA-0000-0000-0000-000000000001"
    private static let surfaceId = "CCCCCCCC-0000-0000-0000-000000000001"
    private static let paneId = "DDDDDDDD-0000-0000-0000-000000000001"
    private static let newSurfaceId = "EEEEEEEE-0000-0000-0000-000000000001"

    private static let cmuxCLIPath = "\(cmuxBundlePath)/Contents/Resources/bin/cmux"

    init() {
        // The fork dispatch is async in production (background queue, off
        // @MainActor). Override to sync so CLI-sequence assertions made right
        // after `fork(...)` returns are deterministic. Swift Testing
        // re-instantiates the suite per test, so this runs before each.
        TerminalController.forkExecutor = { $0() }
    }

    /// Stage cmux CLI fixture: a fake `cmux.app` bundle with an executable at
    /// `Contents/Resources/bin/cmux` so `FileManager.isExecutableFile(atPath:)`
    /// returns true. The mock environment intercepts execution; the file just
    /// needs to exist and be executable.
    private static func setupCmuxBundleFixture() {
        let dir = "\(cmuxBundlePath)/Contents/Resources/bin"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cli = cmuxCLIPath
        if !FileManager.default.fileExists(atPath: cli) {
            FileManager.default.createFile(atPath: cli, contents: Data("#!/bin/sh\n".utf8))
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
    }

    private static func treeJSON(includeSurface: Bool, paneSurfaces: [String]) -> String {
        let surfacesJSON = paneSurfaces.map { id in
            "{\"id\": \"\(id)\", \"pane_id\": \"\(paneId)\"}"
        }.joined(separator: ", ")
        let extraSurface = includeSurface
            ? ", {\"id\": \"\(surfaceId)\", \"pane_id\": \"\(paneId)\"}"
            : ""
        return """
            {
              "windows": [{
                "workspaces": [{
                  "panes": [
                    {"surfaces": [\(surfacesJSON)\(extraSurface)]}
                  ]
                }]
              }]
            }
            """
    }

    @Test("cmux session with surfaceId invokes new-surface CLI and sends fork command")
    func cmuxAdjacentInvokesCLISequence() {
        Self.setupCmuxBundleFixture()
        let env = MockSystemEnvironment()
        env.appBundleURLs[Self.cmuxBundleId] = URL(fileURLWithPath: Self.cmuxBundlePath)

        // 1) lookupCmuxPaneId — surface present in pane.
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["tree"],
            response: Self.treeJSON(includeSurface: true, paneSurfaces: ["existing"])
        ))
        // 2) createCmuxSurface: snapshot before — has just `existing`.
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["tree"],
            response: Self.treeJSON(includeSurface: true, paneSurfaces: ["existing"])
        ))
        // 3) createCmuxSurface: new-surface succeeds.
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["new-surface"],
            response: ""
        ))
        // 4) createCmuxSurface: snapshot after — has `existing` and the new surface.
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["tree"],
            response: Self.treeJSON(includeSurface: true, paneSurfaces: ["existing", Self.newSurfaceId])
        ))
        // 5) `send` succeeds (must capture exit status now — fire-and-forget would mask failure).
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["send"],
            response: ""
        ))

        let result = TerminalController.fork(
            command: "claude --resume abc --fork-session",
            directory: "/tmp",
            bundleId: Self.cmuxBundleId,
            sourceWindowId: "\(Self.workspaceId)|\(Self.surfaceId)",
            environment: env
        )

        #expect(result == true)
        // No AppleScript / no Cmd-T keystroke.
        #expect(env.executedScripts.isEmpty)
        // CLI was invoked at least for new-surface and send.
        let newSurfaceCall = env.shellCommands.contains {
            $0.0.hasSuffix("/cmux") && $0.1.contains("new-surface") && $0.1.contains(Self.paneId)
        }
        #expect(newSurfaceCall, "expected `cmux new-surface --pane <paneId>` to be called")
        // Verify the send payload end-to-end: `cd '<dir>' && <cmd>\n`. A regression
        // that drops the cd prefix or the trailing newline (so cmux never executes
        // the line) would otherwise pass.
        let expectedPayload = "cd '/tmp' && claude --resume abc --fork-session\n"
        let sendCall = env.shellCommands.contains {
            $0.0.hasSuffix("/cmux")
                && $0.1.contains("send")
                && $0.1.contains(Self.newSurfaceId)
                && $0.1.contains(expectedPayload)
        }
        #expect(sendCall, "expected `cmux send --surface <newSurfaceId> -- '\(expectedPayload)'`")
        // cmux brought forward.
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", Self.cmuxBundleId] })
    }

    @Test("Falls through to resume when cmux CLI binary is not installed")
    func fallsBackWhenCLIMissing() {
        let env = MockSystemEnvironment()
        // No appBundleURLs entry → cmuxCLIPath returns nil.

        let result = TerminalController.fork(
            command: "claude --resume abc --fork-session",
            directory: "/tmp",
            bundleId: Self.cmuxBundleId,
            sourceWindowId: "\(Self.workspaceId)|\(Self.surfaceId)",
            environment: env
        )

        #expect(result == true)  // resume() succeeds for cmux
        #expect(!env.shellCommands.contains { $0.0.hasSuffix("/cmux") })
        // resume's cmux AppleScript dispatched.
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", Self.cmuxBundleId] })
    }

    @Test("Falls through to resume when bundle exists but bundled CLI binary is missing")
    func fallsBackWhenBundleExistsButCLIBinaryMissing() {
        // Bundle path with no Contents/Resources/bin/cmux inside — simulates a
        // corrupted/partial cmux install where Launch Services still resolves the
        // bundle but the bundled CLI is gone. Distinct from `fallsBackWhenCLIMissing`,
        // which exercises the case where Launch Services itself returns no bundle.
        let bundlePath = "/tmp/seshctl-test-fixture-no-cli/cmux.app"
        try? FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
        let cli = "\(bundlePath)/Contents/Resources/bin/cmux"
        try? FileManager.default.removeItem(atPath: cli)

        let env = MockSystemEnvironment()
        env.appBundleURLs[Self.cmuxBundleId] = URL(fileURLWithPath: bundlePath)

        let result = TerminalController.fork(
            command: "claude --resume abc --fork-session",
            directory: "/tmp",
            bundleId: Self.cmuxBundleId,
            sourceWindowId: "\(Self.workspaceId)|\(Self.surfaceId)",
            environment: env
        )

        #expect(result == true)  // resume() succeeds for cmux
        // No cmux CLI invocation — cmuxCLIPath returned nil at the FileManager check.
        #expect(!env.shellCommands.contains { $0.0.hasSuffix("/cmux") })
        // resume's cmux AppleScript dispatched.
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", Self.cmuxBundleId] })
    }

    @Test("Falls through to resume when source surface UUID is stale")
    func fallsBackWhenSurfaceStale() {
        Self.setupCmuxBundleFixture()
        let env = MockSystemEnvironment()
        env.appBundleURLs[Self.cmuxBundleId] = URL(fileURLWithPath: Self.cmuxBundlePath)
        // Tree response that does NOT contain our surfaceId.
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["tree"],
            response: Self.treeJSON(includeSurface: false, paneSurfaces: ["other"])
        ))

        let result = TerminalController.fork(
            command: "claude --resume abc --fork-session",
            directory: "/tmp",
            bundleId: Self.cmuxBundleId,
            sourceWindowId: "\(Self.workspaceId)|\(Self.surfaceId)",
            environment: env
        )

        #expect(result == true)
        // tree was queried, but new-surface was never called.
        #expect(env.shellCommands.contains { $0.0.hasSuffix("/cmux") && $0.1.contains("tree") })
        #expect(!env.shellCommands.contains { $0.1.contains("new-surface") })
    }

    @Test("Falls through to resume when windowId has no surface (legacy)")
    func fallsBackWhenNoSurfaceInWindowId() {
        Self.setupCmuxBundleFixture()
        let env = MockSystemEnvironment()
        env.appBundleURLs[Self.cmuxBundleId] = URL(fileURLWithPath: Self.cmuxBundlePath)

        let result = TerminalController.fork(
            command: "claude --resume abc --fork-session",
            directory: "/tmp",
            bundleId: Self.cmuxBundleId,
            sourceWindowId: Self.workspaceId,  // no | separator
            environment: env
        )

        #expect(result == true)
        // cmux CLI never touched.
        #expect(!env.shellCommands.contains { $0.0.hasSuffix("/cmux") })
    }

    @Test("Non-cmux bundle delegates straight to resume")
    func nonCmuxDelegates() {
        let env = MockSystemEnvironment()

        let result = TerminalController.fork(
            command: "claude --resume abc --fork-session",
            directory: "/tmp",
            bundleId: "com.apple.Terminal",
            sourceWindowId: nil,
            environment: env
        )

        #expect(result == true)
        // cmux CLI must not be touched for non-cmux bundles.
        #expect(!env.shellCommands.contains { $0.0.hasSuffix("/cmux") })
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.apple.Terminal"] })
    }

    @Test("Returns false when bundleId is nil")
    func nilBundleIdFails() {
        let env = MockSystemEnvironment()
        let result = TerminalController.fork(
            command: "claude --resume abc --fork-session",
            directory: "/tmp",
            bundleId: nil,
            sourceWindowId: nil,
            environment: env
        )
        #expect(result == false)
    }

    // MARK: - Cmux dispatch failure modes (each must fall through to resume)

    @Test("Aborts and falls through when before-snapshot fails (no nil coercion to empty Set)")
    func fallsBackWhenBeforeSnapshotFails() {
        Self.setupCmuxBundleFixture()
        let env = MockSystemEnvironment()
        env.appBundleURLs[Self.cmuxBundleId] = URL(fileURLWithPath: Self.cmuxBundlePath)
        // 1) lookupCmuxPaneId — surface present (so we proceed past pane lookup).
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["tree"],
            response: Self.treeJSON(includeSurface: true, paneSurfaces: ["live-shell"])
        ))
        // 2) createCmuxSurface before-snapshot: simulate CLI failure (no matching response → nil).

        _ = TerminalController.fork(
            command: "claude --resume abc --fork-session",
            directory: "/tmp",
            bundleId: Self.cmuxBundleId,
            sourceWindowId: "\(Self.workspaceId)|\(Self.surfaceId)",
            environment: env
        )

        // Critical: when the before-snapshot fails we must NOT call new-surface,
        // because doing so without a valid `beforeIds` would let the diff land
        // on a pre-existing live surface and `cmux send` would type into it.
        #expect(!env.shellCommands.contains { $0.1.contains("new-surface") })
        #expect(!env.shellCommands.contains { $0.1.contains("send") })
        // Falls through to resume (cmux AppleScript path) → open -b for activation.
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", Self.cmuxBundleId] })
    }

    @Test("Aborts and falls through when new-surface fails")
    func fallsBackWhenNewSurfaceFails() {
        Self.setupCmuxBundleFixture()
        let env = MockSystemEnvironment()
        env.appBundleURLs[Self.cmuxBundleId] = URL(fileURLWithPath: Self.cmuxBundlePath)
        // 1) lookup, 2) before-snapshot — both succeed.
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["tree"],
            response: Self.treeJSON(includeSurface: true, paneSurfaces: ["existing"])
        ))
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["tree"],
            response: Self.treeJSON(includeSurface: true, paneSurfaces: ["existing"])
        ))
        // 3) new-surface fails (no staged response → nil).

        _ = TerminalController.fork(
            command: "claude --resume abc --fork-session",
            directory: "/tmp",
            bundleId: Self.cmuxBundleId,
            sourceWindowId: "\(Self.workspaceId)|\(Self.surfaceId)",
            environment: env
        )

        #expect(env.shellCommands.contains { $0.1.contains("new-surface") })
        // No after-snapshot polling and no send — we bailed on new-surface.
        #expect(!env.shellCommands.contains { $0.1.contains("send") })
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", Self.cmuxBundleId] })
    }

    @Test("Retries after-snapshot then falls through when diff stays empty")
    func fallsBackWhenAfterSnapshotEmpty() {
        Self.setupCmuxBundleFixture()
        let env = MockSystemEnvironment()
        env.appBundleURLs[Self.cmuxBundleId] = URL(fileURLWithPath: Self.cmuxBundlePath)
        // 1) lookup
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["tree"],
            response: Self.treeJSON(includeSurface: true, paneSurfaces: ["existing"])
        ))
        // 2) before-snapshot
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["tree"],
            response: Self.treeJSON(includeSurface: true, paneSurfaces: ["existing"])
        ))
        // 3) new-surface succeeds
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["new-surface"],
            response: ""
        ))
        // 4-6) after-snapshot retried 3 times — every response identical to before,
        // so subtracting() returns empty.
        for _ in 0..<3 {
            env.stdoutResponses.append(.init(
                pathSuffix: "/cmux", argsContains: ["tree"],
                response: Self.treeJSON(includeSurface: true, paneSurfaces: ["existing"])
            ))
        }

        _ = TerminalController.fork(
            command: "claude --resume abc --fork-session",
            directory: "/tmp",
            bundleId: Self.cmuxBundleId,
            sourceWindowId: "\(Self.workspaceId)|\(Self.surfaceId)",
            environment: env
        )

        // tree was queried for: lookup + before + 3 retries = 5 times total.
        let treeCallCount = env.shellCommands.filter {
            $0.0.hasSuffix("/cmux") && $0.1.contains("tree")
        }.count
        #expect(treeCallCount == 5, "expected 1 lookup + 1 before + 3 retry tree calls, got \(treeCallCount)")
        // Send was never called — we couldn't recover the new surface UUID.
        #expect(!env.shellCommands.contains { $0.1.contains("send") })
        // Fall-through to resume.
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", Self.cmuxBundleId] })
    }

    @Test("Falls through to resume when send fails (silent-failure regression guard)")
    func fallsBackWhenSendFails() {
        Self.setupCmuxBundleFixture()
        let env = MockSystemEnvironment()
        env.appBundleURLs[Self.cmuxBundleId] = URL(fileURLWithPath: Self.cmuxBundlePath)
        // 1) lookup
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["tree"],
            response: Self.treeJSON(includeSurface: true, paneSurfaces: ["existing"])
        ))
        // 2) before
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["tree"],
            response: Self.treeJSON(includeSurface: true, paneSurfaces: ["existing"])
        ))
        // 3) new-surface
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["new-surface"],
            response: ""
        ))
        // 4) after — new surface visible.
        env.stdoutResponses.append(.init(
            pathSuffix: "/cmux", argsContains: ["tree"],
            response: Self.treeJSON(includeSurface: true, paneSurfaces: ["existing", Self.newSurfaceId])
        ))
        // 5) send fails (no staged response → nil).

        _ = TerminalController.fork(
            command: "claude --resume abc --fork-session",
            directory: "/tmp",
            bundleId: Self.cmuxBundleId,
            sourceWindowId: "\(Self.workspaceId)|\(Self.surfaceId)",
            environment: env
        )

        // send was attempted (we have the surface UUID) but failed.
        #expect(env.shellCommands.contains {
            $0.0.hasSuffix("/cmux") && $0.1.contains("send") && $0.1.contains(Self.newSurfaceId)
        })
        // Fall-through to resume — open -b fires.
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", Self.cmuxBundleId] })
    }
}

// MARK: - Resume Script Tests

@Suite("TerminalController - buildResumeScript")
struct BuildResumeScriptTests {

    @Test("Terminal.app script contains do script and escaped command")
    func terminalScript() {
        let script = TerminalController.buildResumeScript(
            command: "claude --resume abc-123",
            directory: "/tmp/project",
            app: .terminal
        )

        #expect(script != nil)
        #expect(script!.contains("do script"))
        #expect(script!.contains("claude --resume abc-123"))
        // Verify the new-tab sequence appears in correct order
        let keystrokeRange = script!.range(of: "keystroke \"t\" using command down")!
        let delayRange = script!.range(of: "delay 0.3")!
        let doScriptRange = script!.range(of: "selected tab of front window")!
        #expect(keystrokeRange.lowerBound < delayRange.lowerBound)
        #expect(delayRange.lowerBound < doScriptRange.lowerBound)
    }

    @Test("iTerm2 script contains write text and escaped command")
    func itermScript() {
        let script = TerminalController.buildResumeScript(
            command: "claude --resume abc-123",
            directory: "/tmp/project",
            app: .iterm2
        )

        #expect(script != nil)
        #expect(script!.contains("write text"))
        #expect(script!.contains("claude --resume abc-123"))
    }

    @Test("Ghostty script uses native working directory and initial input")
    func ghosttyScript() {
        let script = TerminalController.buildResumeScript(
            command: "claude --resume abc-123",
            directory: "/tmp/project",
            app: .ghostty
        )

        #expect(script != nil)
        #expect(script!.contains("tell application \"Ghostty\""))
        #expect(script!.contains("new surface configuration"))
        #expect(script!.contains("initial working directory of cfg to \"/tmp/project\""))
        #expect(script!.contains("initial input of cfg to \"claude --resume abc-123\" & return"))
        #expect(script!.contains("new tab in front window with configuration cfg"))
        #expect(script!.contains("new window with configuration cfg"))
    }

    @Test("Warp script uses System Events with keystroke for new tab and command execution")
    func warpScript() {
        let script = TerminalController.buildResumeScript(
            command: "claude --resume abc-123",
            directory: "/tmp/project",
            app: .warp
        )

        #expect(script != nil)
        #expect(script!.contains("keystroke \"t\" using command down"))
        #expect(script!.contains("claude --resume abc-123"))
        #expect(script!.contains("keystroke return"))
        #expect(script!.contains("delay"))
    }

    @Test("cmux resume script uses new tab + input text with POSIX-quoted cd payload")
    func cmuxScript() {
        let script = TerminalController.buildResumeScript(
            command: "claude --resume abc-123",
            directory: "/tmp/project",
            app: .cmux
        )

        #expect(script != nil)
        #expect(script!.contains("tell application \"cmux\""))
        #expect(script!.contains("new tab in w"))
        #expect(script!.contains("new window"))
        #expect(script!.contains("select tab t"))
        #expect(script!.contains("input text"))
        // The shell payload is wrapped with POSIX single quotes around the dir.
        #expect(script!.contains("cd '/tmp/project' && claude --resume abc-123"))
        // The newline is appended in AppleScript via `& return` (escapeForAppleScript
        // strips literal linefeeds, so we never embed one in the string literal).
        #expect(script!.contains("& return"))
        #expect(script!.contains("focused terminal of t"))
    }

    @Test("cmux resume script escapes single quotes in directory using POSIX trick")
    func cmuxScriptSingleQuotedDirectory() {
        // POSIX single-quoted strings close the quote, inject an escaped quote,
        // and reopen: foo'bar  =>  'foo'\''bar'
        let script = TerminalController.buildResumeScript(
            command: "claude --resume abc",
            directory: "/tmp/wei'rd",
            app: .cmux
        )

        #expect(script != nil)
        // The shell payload before AppleScript escaping is:
        //     cd '/tmp/wei'\''rd' && claude --resume abc
        // escapeForAppleScript doubles every backslash for the AppleScript
        // string literal, so the script source contains a literal `\\` where
        // POSIX saw a single `\`. (When AppleScript parses the string, it
        // collapses `\\` back to `\` before handing the text to `input text`,
        // so the shell receives the correct POSIX-quoted form.)
        #expect(script!.contains("cd '/tmp/wei'\\\\''rd' && claude --resume abc"))
    }

    @Test("Unknown bundle ID returns nil")
    func unknownBundleId() {
        let script = TerminalController.buildResumeScript(
            command: "claude --resume abc-123",
            directory: "/tmp/project",
            app: nil
        )

        #expect(script == nil)
    }

    @Test("Special characters in command are properly escaped")
    func specialCharactersEscaped() {
        let command = "claude --resume \"conv-123\" --flag 'value\\path'"
        let script = TerminalController.buildResumeScript(
            command: command,
            directory: "/tmp/project",
            app: .terminal
        )

        #expect(script != nil)
        // Quotes should be escaped for AppleScript
        #expect(script!.contains("\\\""))
        // Backslashes should be escaped for AppleScript
        #expect(script!.contains("\\\\"))
    }
}

// MARK: - Resume Routing Tests

@Suite("TerminalController - resume routing")
struct ResumeRoutingTests {

    @Test("Returns false when bundleId is nil")
    func nilBundleIdReturnsFalse() {
        let result = TerminalController.resume(
            command: "claude --resume abc-123",
            directory: "/tmp",
            bundleId: nil
        )
        #expect(result == false)
    }

    @Test("Ghostty resume uses open -b then AppleScript with surface configuration")
    func ghosttyResumeRouting() {
        let env = MockSystemEnvironment()
        env.runningApps = ["com.mitchellh.ghostty"]

        let result = TerminalController.resume(
            command: "claude --resume abc-123",
            directory: "/tmp",
            bundleId: "com.mitchellh.ghostty",
            environment: env
        )

        #expect(result == true)
        // open -b should be called to activate the app
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.mitchellh.ghostty"] })
        // AppleScript should use surface configuration with initial input (run after delay so check count)
        // The script is dispatched async after 0.3s, so it won't be in executedScripts immediately.
        // But open -b is called synchronously.
    }

    @Test("Warp resume uses open -b then returns true")
    func warpResumeRouting() {
        let env = MockSystemEnvironment()
        env.runningApps = ["dev.warp.Warp-Stable"]

        let result = TerminalController.resume(
            command: "claude --resume abc-123",
            directory: "/tmp",
            bundleId: "dev.warp.Warp-Stable",
            environment: env
        )

        #expect(result == true)
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "dev.warp.Warp-Stable"] })
    }

    @Test("cmux resume uses open -b then AppleScript (no CLI, no URI)")
    func cmuxResumeRouting() {
        let env = MockSystemEnvironment()
        env.runningApps = ["com.cmuxterm.app"]

        // resume() checks the directory exists — use a real path.
        let tmp = NSTemporaryDirectory()

        let result = TerminalController.resume(
            command: "claude --resume abc",
            directory: tmp,
            bundleId: "com.cmuxterm.app",
            environment: env
        )

        #expect(result == true)
        #expect(env.shellCommands.contains { $0.0 == "/usr/bin/open" && $0.1 == ["-b", "com.cmuxterm.app"] })
        // The AppleScript dispatches after a 0.3s delay, but we can still
        // assert routing via the shellCommand trace (CLI path would have
        // emitted another shell command beyond open -b).
        #expect(env.shellCommands.filter { $0.0 != "/usr/bin/open" }.isEmpty)
        #expect(env.openedURLs.isEmpty)
    }

    @Test("Returns false when directory does not exist")
    func nonexistentDirectoryReturnsFalse() {
        let result = TerminalController.resume(
            command: "claude --resume abc-123",
            directory: "/nonexistent/path/that/does/not/exist",
            bundleId: "com.apple.Terminal"
        )
        #expect(result == false)
    }
}

// MARK: - App Resolution Tests

@Suite("TerminalController - resolveAppBundleId", .serialized)
struct AppResolutionTests {

    private func makeSession(
        hostAppBundleId: String? = nil,
        pid: Int? = nil
    ) -> Session {
        Session(
            id: UUID().uuidString,
            conversationId: "abc-123",
            tool: .claude,
            directory: "/tmp/project",
            launchDirectory: nil,
            hostWorkspaceFolder: nil,
            lastAsk: nil,
            lastReply: nil,
            status: .idle,
            pid: pid,
            hostAppBundleId: hostAppBundleId,
            hostAppName: nil,
            windowId: nil,
            transcriptPath: nil,
            gitRepoName: nil,
            gitBranch: nil,
            launchArgs: nil,
            startedAt: Date(),
            updatedAt: Date(),
            lastReadAt: nil
        )
    }

    @Test("Uses DB bundleId when available")
    func usesDbBundleId() {
        let env = MockSystemEnvironment()

        let session = makeSession(hostAppBundleId: "com.apple.Terminal", pid: 100)
        let result = TerminalController.resolveAppBundleId(session: session, environment: env)
        #expect(result == "com.apple.Terminal")
    }

    @Test("Falls back to PID walk when no DB bundleId")
    func fallsBackToPidWalk() {
        let env = MockSystemEnvironment()
        env.parentPids = [100: 200]
        env.guiApps = [200: "com.googlecode.iterm2"]

        let session = makeSession(hostAppBundleId: nil, pid: 100)
        let result = TerminalController.resolveAppBundleId(session: session, environment: env)
        #expect(result == "com.googlecode.iterm2")
    }

    @Test("Falls back to frontmost terminal when no PID")
    func fallsBackToFrontmostTerminal() {
        let env = MockSystemEnvironment()
        env.runningApps = ["com.apple.Terminal"]

        let session = makeSession(hostAppBundleId: nil, pid: nil)
        let result = TerminalController.resolveAppBundleId(session: session, environment: env)
        // detectFrontmostTerminal checks NSWorkspace.shared.frontmostApplication first,
        // then falls back to running apps matched against TerminalApp.all
        #expect(result == "com.apple.Terminal")
    }

    @Test("Returns nil when nothing available")
    func returnsNilWhenNothingAvailable() {
        let env = MockSystemEnvironment()
        env.runningApps = []

        let session = makeSession(hostAppBundleId: nil, pid: nil)
        let result = TerminalController.resolveAppBundleId(session: session, environment: env)
        #expect(result == nil)
    }
}

// MARK: - Sanitize Launch Args Tests

@Suite("TerminalController - SanitizeLaunchArgs")
struct SanitizeLaunchArgsTests {

    // MARK: stripFlagWithUUIDValue

    @Test("stripFlagWithUUIDValue removes flag and UUID")
    func removesFlagAndUUID() {
        let result = TerminalController.stripFlagWithUUIDValue(
            "--session-id 845ea4dd-6868-4cfa-b73b-5a6299285842 --foo bar",
            flag: "--session-id"
        )
        #expect(result == " --foo bar")
    }

    @Test("stripFlagWithUUIDValue removes UUID flag in middle of args")
    func removesUUIDInMiddleOfArgs() {
        let result = TerminalController.stripFlagWithUUIDValue(
            "--foo bar --session-id 845ea4dd-6868-4cfa-b73b-5a6299285842 --baz",
            flag: "--session-id"
        )
        #expect(result == "--foo bar  --baz")
    }

    @Test("stripFlagWithUUIDValue leaves args alone when flag is missing")
    func leavesAlone_whenFlagMissing_uuid() {
        let input = "--foo bar"
        let result = TerminalController.stripFlagWithUUIDValue(input, flag: "--session-id")
        #expect(result == input)
    }

    @Test("stripFlagWithUUIDValue leaves args alone when flag isn't followed by a UUID")
    func leavesAlone_whenFlagNotFollowedByUUID() {
        let input = "--session-id not-a-uuid --foo"
        let result = TerminalController.stripFlagWithUUIDValue(input, flag: "--session-id")
        #expect(result == input)
    }

    @Test("stripFlagWithUUIDValue is case-insensitive on hex digits")
    func caseInsensitiveHexInUUID() {
        let result = TerminalController.stripFlagWithUUIDValue(
            "--session-id ABCDEF12-3456-7890-ABCD-EF1234567890",
            flag: "--session-id"
        )
        #expect(result == "")
    }

    // MARK: stripFlagWithJSONValue

    @Test("stripFlagWithJSONValue removes simple JSON value")
    func removesSimpleJSON() {
        let result = TerminalController.stripFlagWithJSONValue(
            "--settings {\"a\":1} --foo bar",
            flag: "--settings"
        )
        #expect(result == " --foo bar")
    }

    @Test("stripFlagWithJSONValue removes nested JSON value")
    func removesNestedJSON() {
        let result = TerminalController.stripFlagWithJSONValue(
            "--settings {\"hooks\":{\"x\":[1,2]}} --foo",
            flag: "--settings"
        )
        #expect(result == " --foo")
    }

    @Test("stripFlagWithJSONValue handles spaces inside JSON string values")
    func removesJSONWithSpacesInsideStrings() {
        let result = TerminalController.stripFlagWithJSONValue(
            "--settings {\"cmd\":\"echo hi\"} --foo",
            flag: "--settings"
        )
        #expect(result == " --foo")
    }

    @Test("stripFlagWithJSONValue ignores braces inside JSON string values")
    func removesJSONWithBracesInsideStrings() {
        let result = TerminalController.stripFlagWithJSONValue(
            "--settings {\"foo\":\"a } b\"} --baz",
            flag: "--settings"
        )
        #expect(result == " --baz")
    }

    @Test("stripFlagWithJSONValue handles escaped quotes inside JSON string values")
    func removesJSONWithEscapedQuotesInsideStrings() {
        let result = TerminalController.stripFlagWithJSONValue(
            "--settings {\"cmd\":\"echo \\\"hi\\\"\"} --foo",
            flag: "--settings"
        )
        #expect(result == " --foo")
    }

    @Test("stripFlagWithJSONValue leaves args alone when flag is missing")
    func leavesAlone_whenFlagMissing_json() {
        let input = "--foo {bar}"
        let result = TerminalController.stripFlagWithJSONValue(input, flag: "--settings")
        #expect(result == input)
    }

    @Test("stripFlagWithJSONValue leaves args alone when value doesn't start with brace")
    func leavesAlone_whenValueDoesntStartWithBrace() {
        let input = "--settings notjson --foo"
        let result = TerminalController.stripFlagWithJSONValue(input, flag: "--settings")
        #expect(result == input)
    }

    @Test("stripFlagWithJSONValue leaves args alone when braces are unbalanced")
    func leavesAlone_whenBracesUnbalanced() {
        let input = "--settings {\"foo\":1 --next"
        let result = TerminalController.stripFlagWithJSONValue(input, flag: "--settings")
        #expect(result == input)
    }

    @Test("stripFlagWithUUIDValue leaves args alone when flag is a suffix of another flag")
    func leavesAlone_whenFlagIsSuffixOfAnotherFlag_uuid() {
        let input = "--my-session-id 845ea4dd-6868-4cfa-b73b-5a6299285842 --foo"
        let result = TerminalController.stripFlagWithUUIDValue(input, flag: "--session-id")
        #expect(result == input)
    }

    @Test("stripFlagWithJSONValue leaves args alone when flag is a suffix of another flag")
    func leavesAlone_whenFlagIsSuffixOfAnotherFlag_json() {
        let input = "--my-settings {\"a\":1} --foo"
        let result = TerminalController.stripFlagWithJSONValue(input, flag: "--settings")
        #expect(result == input)
    }

    // MARK: stripUnshellableFlags (integration of the two)

    @Test("stripUnshellableFlags strips both flags and cleans up spaces")
    func stripsBothFlagsAndCleansSpaces() {
        let input = "--session-id 845ea4dd-6868-4cfa-b73b-5a6299285842 --settings {\"hooks\":{\"SessionStart\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"\\\"${X:-cmux}\\\" claude-hook session-start\",\"timeout\":10}]}]}} --dangerously-skip-permissions"
        let result = TerminalController.stripUnshellableFlags(input)
        #expect(result == "--dangerously-skip-permissions")
    }

    @Test("stripUnshellableFlags preserves user flags when no targeted flags are present")
    func preservesUserFlags() {
        let input = "--dangerously-skip-permissions --verbose"
        let result = TerminalController.stripUnshellableFlags(input)
        #expect(result == input)
    }

    @Test("stripUnshellableFlags handles empty input")
    func handlesEmpty() {
        let result = TerminalController.stripUnshellableFlags("")
        #expect(result == "")
    }

    @Test("stripUnshellableFlags strips only --settings when --session-id is missing")
    func stripsOnlySettings_whenSessionIdMissing() {
        let result = TerminalController.stripUnshellableFlags("--settings {\"a\":1} --foo")
        #expect(result == "--foo")
    }

    @Test("stripUnshellableFlags strips only --session-id when --settings is missing")
    func stripsOnlySessionId_whenSettingsMissing() {
        let result = TerminalController.stripUnshellableFlags(
            "--session-id 845ea4dd-6868-4cfa-b73b-5a6299285842 --foo"
        )
        #expect(result == "--foo")
    }
}
