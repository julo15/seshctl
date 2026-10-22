import AppKit
import ArgumentParser
import Foundation
import SeshctlCore

@main
struct SeshctlCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seshctl-cli",
        abstract: "Track and manage active LLM CLI sessions.",
        subcommands: [Start.self, Update.self, End.self, List.self, Show.self, GC.self, Install.self, Uninstall.self]
    )
}

// MARK: - Helpers

func openDatabase() throws -> SeshctlDatabase {
    let path = NSString(
        string: "~/.local/share/seshctl/seshctl.db"
    ).expandingTildeInPath
    return try SeshctlDatabase(path: path)
}

extension SessionTool: ExpressibleByArgument {}
extension SessionStatus: ExpressibleByArgument {}

// MARK: - Start

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a new session."
    )

    @Option(help: "Tool name (claude, gemini, codex, cursor).")
    var tool: SessionTool

    @Option(help: "Working directory.")
    var dir: String

    @Option(help: "CLI process PID. Required for tools whose hook PPID is stable across events (Claude, Codex). Omit for tools that key on --conversation-id (Cursor).")
    var pid: Int?

    @Option(name: .long, help: "Conversation/session ID from the CLI. With --pid, written onto the new row. Without --pid, used as the matcher key (required for tools whose hook PPID is not stable, e.g. Cursor).")
    var conversationId: String?

    @Option(name: .long, help: "Host app bundle ID (e.g., com.microsoft.VSCode).")
    var hostAppBundleId: String?

    @Option(name: .long, help: "Host app name (e.g., Code).")
    var hostAppName: String?

    @Option(name: .long, help: "Transcript file path.")
    var transcriptPath: String?

    @Option(name: .long, help: "Override launch args (for testing).")
    var launchArgs: String?

    @Option(name: .long, help: "Terminal-specific window/tab/surface ID for focusing.")
    var windowId: String?

    func run() throws {
        // Require at least one stable identifier. When both are present, PID
        // is the matcher and conversation id is metadata written onto the row.
        switch (pid, conversationId) {
        case (nil, nil):
            throw ValidationError("Provide exactly one of --pid or --conversation-id.")
        case (.some, .some):
            // Both set is valid for the pid-keyed path: --conversation-id is
            // written onto the row created for --pid. Fall through.
            break
        default:
            break
        }

        let db = try openDatabase()

        if let pid {
            // Auto-detect host app from PID if not provided
            var bundleId = hostAppBundleId
            var appName = hostAppName
            if bundleId == nil {
                let detected = detectHostApp(pid: Int32(pid))
                bundleId = detected.bundleId
                appName = detected.name
            }

            // Capture launch args from the process (or use override)
            let capturedArgs = launchArgs ?? captureLaunchArgs(pid: pid)

            // Detect git context
            let gitContext = GitContext.detect(directory: dir)

            let hostWorkspaceFolder = VSCodeWindowMap.lookup(
                startPid: pid,
                directory: VSCodeWindowMap.defaultDirectory()
            )

            let session = try db.startSession(
                tool: tool, directory: dir, pid: pid,
                conversationId: conversationId,
                hostAppBundleId: bundleId, hostAppName: appName,
                windowId: windowId,
                transcriptPath: transcriptPath,
                gitRepoName: gitContext.repoName, gitBranch: gitContext.branch,
                launchArgs: capturedArgs,
                launchDirectory: dir,
                hostWorkspaceFolder: hostWorkspaceFolder
            )
            print(session.id)
        } else if let conversationId {
            // Conversation-id-keyed path: no stable PID to record, no
            // PID-derived auto-detect or launch-args capture. Host-app fields
            // must be supplied explicitly by the caller (the cursor hook
            // passes them; see hooks/cursor/session-start.sh).
            let gitContext = GitContext.detect(directory: dir)

            let session = try db.startSession(
                conversationId: conversationId,
                tool: tool, directory: dir,
                hostAppBundleId: hostAppBundleId, hostAppName: hostAppName,
                windowId: windowId,
                transcriptPath: transcriptPath,
                gitRepoName: gitContext.repoName, gitBranch: gitContext.branch,
                launchArgs: launchArgs,
                launchDirectory: dir,
                hostWorkspaceFolder: nil
            )
            print(session.id)
        }
    }

    private func detectHostApp(pid: pid_t) -> (bundleId: String?, name: String?) {
        let processInfo = RealProcessInfoProvider()
        var currentPid = pid
        for _ in 0..<10 {
            let parentPid = pid_t(processInfo.parentPid(of: Int(currentPid)))

            // Try to find app by checking running apps
            for app in NSWorkspace.shared.runningApplications {
                if app.processIdentifier == currentPid && app.activationPolicy == .regular {
                    return (app.bundleIdentifier, app.localizedName)
                }
            }

            if parentPid <= 1 || parentPid == currentPid { break }
            currentPid = parentPid
        }

        // Fallback: PID walk failed (e.g. Ghostty spawns shells via login(1) which
        // runs as root, making proc_pidinfo unable to read its parent PID).
        // First check TERM_PROGRAM env var (set by many terminals), then frontmost app.
        if let app = TerminalApp.from(environment: ProcessInfo.processInfo.environment) {
            let name = NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == app.bundleId }?.localizedName ?? app.displayName
            return (app.bundleId, name)
        }
        let knownBundleIds = Set(TerminalApp.allBundleIds)
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.activationPolicy == .regular,
           let bid = frontApp.bundleIdentifier,
           knownBundleIds.contains(bid) {
            return (bid, frontApp.localizedName)
        }

        return (nil, nil)
    }

    private func captureLaunchArgs(pid: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "args="]
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Strip binary name (first component)
        let components = trimmed.split(separator: " ", maxSplits: 1)
        guard components.count > 1 else { return nil }
        let args = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return args.isEmpty ? nil : args
    }
}

// MARK: - Update

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Update the active session, matched by --pid or --conversation-id."
    )

    @Option(help: "CLI process PID.")
    var pid: Int?

    @Option(help: "Tool name (claude, gemini, codex, cursor).")
    var tool: SessionTool

    @Option(help: "User's message/prompt.")
    var ask: String?

    @Option(help: "Assistant's last response text.")
    var reply: String?

    @Option(help: "New status (idle, working, waiting).")
    var status: SessionStatus?

    @Option(name: .long, help: "Transcript file path.")
    var transcriptPath: String?

    @Option(name: .long, help: "Conversation/session ID. With --pid, written onto the matched row. Without --pid, used as the matcher key.")
    var conversationId: String?

    @Option(name: .long, help: "Working directory.")
    var dir: String?

    @Option(name: .long, help: "Host app bundle ID (e.g., com.todesktop.230313mzl4w4u92). Used to fill host-app fields on the lazy-create path when sessionStart was missed.")
    var hostAppBundleId: String?

    @Option(name: .long, help: "Host app name (e.g., Cursor). Used to fill host-app fields on the lazy-create path when sessionStart was missed.")
    var hostAppName: String?

    @Flag(name: .long, help: "Skip git context detection (faster for status-only updates).")
    var skipGit = false

    func run() throws {
        try Self.validateMatchers(pid: pid, conversationId: conversationId)

        let db = try openDatabase()

        if let pid {
            var gitRepoName: String?
            var gitBranch: String?
            if !skipGit, let session = try db.findActiveSession(pid: pid, tool: tool) {
                let gitContext = GitContext.detect(directory: dir ?? session.directory)
                gitRepoName = gitContext.repoName
                gitBranch = gitContext.branch
            }

            try db.updateSession(pid: pid, tool: tool, ask: ask, reply: reply, status: status, transcriptPath: transcriptPath, conversationId: conversationId, directory: dir, gitRepoName: gitRepoName, gitBranch: gitBranch, hostAppBundleId: hostAppBundleId, hostAppName: hostAppName)
        } else if let conversationId {
            var gitRepoName: String?
            var gitBranch: String?
            if !skipGit, let session = try db.findActiveSession(conversationId: conversationId, tool: tool) {
                let gitContext = GitContext.detect(directory: dir ?? session.directory)
                gitRepoName = gitContext.repoName
                gitBranch = gitContext.branch
            }

            try db.updateSession(conversationId: conversationId, tool: tool, ask: ask, reply: reply, status: status, transcriptPath: transcriptPath, directory: dir, gitRepoName: gitRepoName, gitBranch: gitBranch, hostAppBundleId: hostAppBundleId, hostAppName: hostAppName)
        }
    }

    static func validateMatchers(pid: Int?, conversationId: String?) throws {
        switch (pid, conversationId) {
        case (nil, nil):
            throw ValidationError("Provide exactly one of --pid or --conversation-id.")
        case (.some, .some):
            // PID is the matcher; conversation id is metadata written onto
            // the matched row. Codex sends both on UserPromptSubmit.
            break
        default:
            break
        }
    }
}

// MARK: - End

struct End: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "End the active session, matched by --pid or --conversation-id."
    )

    @Option(help: "CLI process PID.")
    var pid: Int?

    @Option(help: "Tool name (claude, gemini, codex, cursor).")
    var tool: SessionTool

    @Option(name: .long, help: "Conversation/session ID.")
    var conversationId: String?

    @Option(help: "Final status (completed, canceled).")
    var status: SessionStatus?

    @Option(name: .long, help: "Host app bundle ID. Accepted for parity with `update` (e.g. Cursor passes this on every event); currently unused on the end path because there is no lazy-create branch.")
    var hostAppBundleId: String?

    @Option(name: .long, help: "Host app name. Accepted for parity with `update`; currently unused on the end path.")
    var hostAppName: String?

    func run() throws {
        // Require exactly one matcher.
        switch (pid, conversationId) {
        case (nil, nil):
            throw ValidationError("Provide exactly one of --pid or --conversation-id.")
        case (.some, .some):
            throw ValidationError("Provide exactly one of --pid or --conversation-id, not both.")
        default:
            break
        }

        let db = try openDatabase()
        if let pid {
            try db.endSession(pid: pid, tool: tool, status: status ?? .completed)
        } else if let conversationId {
            try db.endSession(conversationId: conversationId, tool: tool, status: status ?? .completed)
        }
    }
}

// MARK: - List

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List sessions ordered by most recently updated."
    )

    @Option(help: "Max number of sessions to show.")
    var limit: Int = 20

    @Option(help: "Filter by status.")
    var status: SessionStatus?

    @Option(help: "Filter by tool.")
    var tool: SessionTool?

    func run() throws {
        let db = try openDatabase()
        let sessions = try db.listSessions(limit: limit, status: status, tool: tool)

        if sessions.isEmpty {
            print("No sessions found.")
            return
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated

        for session in sessions {
            let age = formatter.localizedString(for: session.updatedAt, relativeTo: Date())
            let dir = session.displayName
            let ask = session.lastAsk.map { " \"\(String($0.prefix(60)))\"" } ?? ""
            print(
                "\(session.id.prefix(8))  \(session.tool.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(session.status.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(dir.padding(toLength: 40, withPad: " ", startingAt: 0)) \(age)\(ask)"
            )
        }
    }
}

// MARK: - Show

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show full details for a session."
    )

    @Argument(help: "Session ID (full UUID or prefix).")
    var id: String

    func run() throws {
        let db = try openDatabase()

        guard let session = try db.getSession(id: id) else {
            throw ValidationError("Session not found: \(id)")
        }

        let iso = ISO8601DateFormatter()
        print("ID:              \(session.id)")
        print("Tool:            \(session.tool.rawValue)")
        print("Status:          \(session.status.rawValue)")
        print("Directory:       \(session.directory)")
        if let repo = session.gitRepoName {
            print("Git Repo:        \(repo)")
        }
        if let branch = session.gitBranch {
            print("Git Branch:      \(branch)")
        }
        if let cid = session.conversationId {
            print("Conversation ID: \(cid)")
        }
        if let pid = session.pid {
            print("PID:             \(pid)")
        }
        if let ask = session.lastAsk {
            print("Last Ask:        \(ask)")
        }
        if let reply = session.lastReply {
            print("Last Reply:      \(reply)")
        }
        print("Started:         \(iso.string(from: session.startedAt))")
        print("Updated:         \(iso.string(from: session.updatedAt))")
    }
}

// MARK: - GC

struct GC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Garbage collect old sessions and reap stale ones."
    )

    @Option(help: "Delete completed sessions older than this (e.g., 30d, 7d).")
    var olderThan: String = "30d"

    func run() throws {
        let db = try openDatabase()

        guard let seconds = parseDuration(olderThan) else {
            throw ValidationError("Invalid duration: \(olderThan). Use format like 30d, 7d, 24h.")
        }

        let (deleted, markedStale) = try db.gc(olderThan: seconds)
        print("Deleted \(deleted) old sessions, marked \(markedStale) as stale.")
    }

    private func parseDuration(_ s: String) -> TimeInterval? {
        let pattern = /^(\d+)([dhm])$/
        guard let match = s.wholeMatch(of: pattern) else { return nil }
        let value = Double(match.1)!
        switch match.2 {
        case "d": return value * 86400
        case "h": return value * 3600
        case "m": return value * 60
        default: return nil
        }
    }
}
