import Foundation
import Testing

// MARK: - Test helpers

/// Walks up from this source file to find the repo root (the directory
/// containing `Package.swift`), so tests can locate `hooks/claude/*.sh`.
private func repoRoot() -> URL {
    var url = URL(fileURLWithPath: #file)
    while url.path != "/" {
        url = url.deletingLastPathComponent()
        let candidate = url.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return url
        }
    }
    fatalError("could not find Package.swift walking up from \(#file)")
}

private let jqPath = "/usr/bin/jq"

private func requireJQ() {
    precondition(FileManager.default.isExecutableFile(atPath: jqPath),
                 "jq missing at \(jqPath); test cannot proceed")
}

/// Per-test fake HOME. The hooks write logs and the awaiting-user marker
/// under `$HOME/.local/share/seshctl`, so each test gets its own.
private func makeTempHome() throws -> URL {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("seshctl-claude-hook-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    return temp
}

private func cleanup(_ temp: URL) {
    try? FileManager.default.removeItem(at: temp)
}

private func markerURL(home: URL, sessionId: String) -> URL {
    home.appendingPathComponent(".local/share/seshctl/state/claude-awaiting-user-\(sessionId)")
}

private func hooksLog(home: URL) -> String {
    let url = home.appendingPathComponent(".local/share/seshctl/logs/hooks.log")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

/// Runs a Claude hook script with `payload` on stdin, HOME pointed at
/// `home`, and a stub `seshctl-cli` first on PATH that appends one line per
/// invocation (its argv joined by spaces) to `calls.log`.
///
/// The Claude hooks background their `seshctl-cli` call with `&`, so the
/// stub may write after the script exits. Callers that expect a call pass
/// `expectedCalls` and this polls until that many lines land. The 15s cap is
/// only a hang guard — the loop returns as soon as the line appears — and it
/// must be generous: under the full parallel suite, bash + jq + the stub
/// spawn measured up to ~4.4s, which flaked an earlier 3s cap.
/// Callers expecting no call pass 0; the hooks exit before reaching `&` on
/// those paths, and a short grace period catches any stray late write.
private func runHook(
    named scriptName: String,
    payload: String,
    home: URL,
    expectedCalls: Int
) throws -> [String] {
    let stubDir = home.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)
    let logFile = home.appendingPathComponent("calls.log")
    let stub = stubDir.appendingPathComponent("seshctl-cli")
    let script = """
    #!/bin/bash
    printf '%s\\n' "$*" >> "\(logFile.path)"
    """
    try Data(script.utf8).write(to: stub)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    if !FileManager.default.fileExists(atPath: logFile.path) {
        FileManager.default.createFile(atPath: logFile.path, contents: Data())
    }

    let hookScript = repoRoot()
        .appendingPathComponent("hooks/claude")
        .appendingPathComponent(scriptName)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = [hookScript.path]
    proc.environment = [
        "PATH": "\(stubDir.path):/usr/bin:/bin",
        "HOME": home.path,
    ]
    let inPipe = Pipe()
    proc.standardInput = inPipe
    proc.standardOutput = Pipe()
    proc.standardError = Pipe()
    try proc.run()
    inPipe.fileHandleForWriting.write(Data(payload.utf8))
    try inPipe.fileHandleForWriting.close()
    proc.waitUntilExit()

    func readCalls() -> [String] {
        let text = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    if expectedCalls == 0 {
        Thread.sleep(forTimeInterval: 0.3)
        return readCalls()
    }
    let deadline = Date().addingTimeInterval(15)
    while readCalls().count < expectedCalls && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    return readCalls()
}

private func payload(session: String = "sess-1", tool: String, agentId: String? = nil) -> String {
    var object: [String: String] = ["session_id": session, "tool_name": tool]
    if let agentId { object["agent_id"] = agentId }
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

private func touchMarker(home: URL, sessionId: String = "sess-1") throws {
    let url = markerURL(home: home, sessionId: sessionId)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data())
}

// MARK: - Tests

// Serialized: each case blocks its thread on process exit and polling, and
// running the cases concurrently stacks those waits on top of each other.
@Suite("Claude hook scripts → session status", .serialized)
struct ClaudeHookTests {

    // MARK: pre-tool-use.sh

    @Test("main-session tool call sets working", arguments: ["Bash", "Read", ""])
    func mainToolSetsWorking(tool: String) throws {
        requireJQ()
        let home = try makeTempHome()
        defer { cleanup(home) }

        let calls = try runHook(named: "pre-tool-use.sh", payload: payload(tool: tool),
                                home: home, expectedCalls: 1)
        #expect(calls.count == 1)
        #expect(calls.first?.contains("--status working") == true, "calls: \(calls)")
    }

    @Test("blocking tool sets waiting and drops the marker",
          arguments: ["AskUserQuestion", "ExitPlanMode"])
    func blockingToolSetsWaiting(tool: String) throws {
        requireJQ()
        let home = try makeTempHome()
        defer { cleanup(home) }

        let calls = try runHook(named: "pre-tool-use.sh", payload: payload(tool: tool),
                                home: home, expectedCalls: 1)
        #expect(calls.count == 1)
        #expect(calls.first?.contains("--status waiting") == true, "calls: \(calls)")
        #expect(FileManager.default.fileExists(atPath: markerURL(home: home, sessionId: "sess-1").path))
    }

    /// A subagent permission prompt sets waiting via notification.sh with no
    /// marker. Once approved, the subagent's next tool call must restore
    /// working, or the session stays stuck on waiting for the whole run.
    @Test("subagent tool call sets working when no question is open")
    func subagentSetsWorkingWithoutMarker() throws {
        requireJQ()
        let home = try makeTempHome()
        defer { cleanup(home) }

        let calls = try runHook(named: "pre-tool-use.sh",
                                payload: payload(tool: "Bash", agentId: "agent-1"),
                                home: home, expectedCalls: 1)
        #expect(calls.count == 1)
        #expect(calls.first?.contains("--status working") == true, "calls: \(calls)")
    }

    @Test("subagent tool call leaves an open question alone")
    func subagentSkippedWhileQuestionOpen() throws {
        requireJQ()
        let home = try makeTempHome()
        defer { cleanup(home) }
        try touchMarker(home: home)

        let calls = try runHook(named: "pre-tool-use.sh",
                                payload: payload(tool: "Bash", agentId: "agent-1"),
                                home: home, expectedCalls: 0)
        #expect(calls.isEmpty, "calls: \(calls)")
        #expect(FileManager.default.fileExists(atPath: markerURL(home: home, sessionId: "sess-1").path))
    }

    @Test("main-session tool call clears a leftover marker")
    func mainToolClearsMarker() throws {
        requireJQ()
        let home = try makeTempHome()
        defer { cleanup(home) }
        try touchMarker(home: home)

        let calls = try runHook(named: "pre-tool-use.sh", payload: payload(tool: "Bash"),
                                home: home, expectedCalls: 1)
        #expect(calls.first?.contains("--status working") == true, "calls: \(calls)")
        #expect(!FileManager.default.fileExists(atPath: markerURL(home: home, sessionId: "sess-1").path))
    }

    @Test("marker is scoped per session")
    func markerIsPerSession() throws {
        requireJQ()
        let home = try makeTempHome()
        defer { cleanup(home) }
        try touchMarker(home: home, sessionId: "other-session")

        let calls = try runHook(named: "pre-tool-use.sh",
                                payload: payload(tool: "Bash", agentId: "agent-1"),
                                home: home, expectedCalls: 1)
        #expect(calls.first?.contains("--status working") == true, "calls: \(calls)")
    }

    @Test("session id is sanitized before naming the marker")
    func sessionIdSanitized() throws {
        requireJQ()
        let home = try makeTempHome()
        defer { cleanup(home) }

        _ = try runHook(named: "pre-tool-use.sh",
                        payload: payload(session: "../../evil", tool: "AskUserQuestion"),
                        home: home, expectedCalls: 1)
        #expect(FileManager.default.fileExists(atPath: markerURL(home: home, sessionId: "evil").path))
    }

    @Test("hooks.log tags subagent calls with agent=")
    func logTagsSubagentCalls() throws {
        requireJQ()
        let home = try makeTempHome()
        defer { cleanup(home) }

        _ = try runHook(named: "pre-tool-use.sh", payload: payload(tool: "Bash"),
                        home: home, expectedCalls: 1)
        _ = try runHook(named: "pre-tool-use.sh",
                        payload: payload(tool: "Read", agentId: "agent-1"),
                        home: home, expectedCalls: 2)
        let lines = hooksLog(home: home).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.first?.hasSuffix("PRE_TOOL_USE Bash") == true, "log: \(lines)")
        #expect(lines.last?.hasSuffix("PRE_TOOL_USE Read agent=agent-1") == true, "log: \(lines)")
    }

    // MARK: post-tool-use.sh

    @Test("answering a blocking tool sets working and clears the marker",
          arguments: ["AskUserQuestion", "ExitPlanMode"])
    func postToolUseRestoresWorking(tool: String) throws {
        requireJQ()
        let home = try makeTempHome()
        defer { cleanup(home) }
        try touchMarker(home: home)

        let calls = try runHook(named: "post-tool-use.sh", payload: payload(tool: tool),
                                home: home, expectedCalls: 1)
        #expect(calls.first?.contains("--status working") == true, "calls: \(calls)")
        #expect(!FileManager.default.fileExists(atPath: markerURL(home: home, sessionId: "sess-1").path))
    }

    @Test("post-tool-use ignores non-blocking tools")
    func postToolUseIgnoresOtherTools() throws {
        requireJQ()
        let home = try makeTempHome()
        defer { cleanup(home) }
        try touchMarker(home: home)

        let calls = try runHook(named: "post-tool-use.sh", payload: payload(tool: "Bash"),
                                home: home, expectedCalls: 0)
        #expect(calls.isEmpty, "calls: \(calls)")
        #expect(FileManager.default.fileExists(atPath: markerURL(home: home, sessionId: "sess-1").path))
    }

    // MARK: marker cleanup on turn / session boundaries

    @Test("stop, user-prompt, and session-end clear the marker",
          arguments: ["stop.sh", "user-prompt.sh", "session-end.sh"])
    func boundaryHooksClearMarker(script: String) throws {
        requireJQ()
        let home = try makeTempHome()
        defer { cleanup(home) }
        try touchMarker(home: home)

        _ = try runHook(named: script,
                        payload: #"{"session_id":"sess-1","cwd":"/tmp"}"#,
                        home: home, expectedCalls: 1)
        #expect(!FileManager.default.fileExists(atPath: markerURL(home: home, sessionId: "sess-1").path))
    }
}
