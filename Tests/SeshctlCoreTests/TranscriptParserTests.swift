import Foundation
import Testing

@testable import SeshctlCore

@Suite("TranscriptParser")
struct TranscriptParserTests {

    @Test("Encodes path correctly")
    func encodesPath() {
        #expect(TranscriptParser.encodePath("/Users/foo/bar") == "-Users-foo-bar")
        #expect(TranscriptParser.encodePath("/") == "-")
    }

    @Test("Encodes non-alphanumeric characters Claude treats as separators")
    func encodesNonAlnumSeparators() {
        // The bug this widened encoding catches: paths under `.claude/worktrees/<name+x>`
        // — Claude collapses both `.` and `+` to `-` when naming the project dir,
        // and the original `/`-only transform missed both.
        #expect(
            TranscriptParser.encodePath("/Users/foo/seshctl/.claude/worktrees/julo+row")
                == "-Users-foo-seshctl--claude-worktrees-julo-row"
        )
        // Spaces, punctuation, anything not [A-Za-z0-9_-] also collapses to `-`.
        #expect(TranscriptParser.encodePath("/Users/foo bar") == "-Users-foo-bar")
        #expect(TranscriptParser.encodePath("/Users/foo@bar") == "-Users-foo-bar")
        // Underscores and dashes are preserved.
        #expect(TranscriptParser.encodePath("/Users/foo_bar-baz") == "-Users-foo_bar-baz")
    }

    @Test("Parses user text message (string content)")
    func parsesUserText() throws {
        let jsonl = makeUserLine(content: "\"hello world\"")
        let turns = try TranscriptParser.parse(data: Data(jsonl.utf8))

        #expect(turns.count == 1)
        if case .userMessage(let text, _) = turns[0] {
            #expect(text == "hello world")
        } else {
            Issue.record("Expected userMessage")
        }
    }

    @Test("Parses assistant text message")
    func parsesAssistantText() throws {
        let jsonl = makeAssistantLine(messageId: "msg_1", contentBlocks: [
            "{\"type\": \"text\", \"text\": \"Here is my response.\"}"
        ])
        let turns = try TranscriptParser.parse(data: Data(jsonl.utf8))

        #expect(turns.count == 1)
        if case .assistantMessage(let text, let tools, _) = turns[0] {
            #expect(text == "Here is my response.")
            #expect(tools.isEmpty)
        } else {
            Issue.record("Expected assistantMessage")
        }
    }

    @Test("Merges content blocks by message.id")
    func mergesBlocks() throws {
        let line1 = makeAssistantLine(messageId: "msg_1", contentBlocks: [
            "{\"type\": \"text\", \"text\": \"Starting...\"}"
        ], timestamp: "2026-01-01T00:00:01.000Z")
        let line2 = makeAssistantLine(messageId: "msg_1", contentBlocks: [
            "{\"type\": \"tool_use\", \"id\": \"t1\", \"name\": \"Read\", \"input\": {}}"
        ], timestamp: "2026-01-01T00:00:02.000Z")
        let line3 = makeAssistantLine(messageId: "msg_1", contentBlocks: [
            "{\"type\": \"tool_use\", \"id\": \"t2\", \"name\": \"Edit\", \"input\": {}}"
        ], timestamp: "2026-01-01T00:00:03.000Z")

        let jsonl = [line1, line2, line3].joined(separator: "\n")
        let turns = try TranscriptParser.parse(data: Data(jsonl.utf8))

        #expect(turns.count == 1)
        if case .assistantMessage(let text, let tools, _) = turns[0] {
            #expect(text == "Starting...")
            #expect(tools.count == 2)
            #expect(tools[0].toolName == "Read")
            #expect(tools[1].toolName == "Edit")
        } else {
            Issue.record("Expected assistantMessage")
        }
    }

    @Test("Filters progress entries")
    func filtersProgress() throws {
        let progress = """
        {"type": "progress", "data": {"type": "hook_progress"}, "timestamp": "2026-01-01T00:00:00.000Z"}
        """
        let user = makeUserLine(content: "\"hello\"")
        let jsonl = [progress, user].joined(separator: "\n")
        let turns = try TranscriptParser.parse(data: Data(jsonl.utf8))

        #expect(turns.count == 1)
    }

    @Test("Filters tool_result user messages")
    func filtersToolResults() throws {
        let toolResult = """
        {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}, "timestamp": "2026-01-01T00:00:00.000Z", "uuid": "u1"}
        """
        let turns = try TranscriptParser.parse(data: Data(toolResult.utf8))
        #expect(turns.isEmpty)
    }

    @Test("Strips system-reminder tags")
    func stripsSystemReminders() {
        let input = "hello <system-reminder>secret stuff</system-reminder> world"
        let result = TranscriptParser.stripInternalTags(input)
        #expect(result == "hello  world")
    }

    @Test("Strips multiline system-reminder tags")
    func stripsMultilineSystemReminders() {
        let input = "hello\n<system-reminder>\nline1\nline2\n</system-reminder>\nworld"
        let result = TranscriptParser.stripInternalTags(input)
        #expect(result == "hello\n\nworld")
    }

    @Test("Strips local-command-stdout tags and skips empty turns")
    func stripsLocalCommandTags() {
        let input = "<local-command-stdout>Set model to Opus 4.6</local-command-stdout>"
        let result = TranscriptParser.stripInternalTags(input)
        #expect(result == "")
    }

    @Test("Strips task-notification tags")
    func stripsTaskNotification() {
        let input = "do the thing <task-notification><task-id>abc</task-id><summary>Build done</summary></task-notification>"
        let result = TranscriptParser.stripInternalTags(input)
        #expect(result == "do the thing")
    }

    @Test("Strips thinking blocks from assistant content")
    func stripsThinking() throws {
        let line1 = makeAssistantLine(messageId: "msg_1", contentBlocks: [
            "{\"type\": \"thinking\", \"thinking\": \"secret\", \"signature\": \"abc\"}"
        ], timestamp: "2026-01-01T00:00:01.000Z")
        let line2 = makeAssistantLine(messageId: "msg_1", contentBlocks: [
            "{\"type\": \"text\", \"text\": \"visible response\"}"
        ], timestamp: "2026-01-01T00:00:02.000Z")

        let jsonl = [line1, line2].joined(separator: "\n")
        let turns = try TranscriptParser.parse(data: Data(jsonl.utf8))

        #expect(turns.count == 1)
        if case .assistantMessage(let text, _, _) = turns[0] {
            #expect(text == "visible response")
            #expect(!text.contains("secret"))
        } else {
            Issue.record("Expected assistantMessage")
        }
    }

    @Test("Thinking-only assistant turns are skipped")
    func thinkingOnlySkipped() throws {
        let line = makeAssistantLine(messageId: "msg_1", contentBlocks: [
            "{\"type\": \"thinking\", \"thinking\": \"\", \"signature\": \"abc\"}"
        ])
        let turns = try TranscriptParser.parse(data: Data(line.utf8))
        #expect(turns.isEmpty)
    }

    @Test("Empty data returns empty array")
    func emptyData() throws {
        let turns = try TranscriptParser.parse(data: Data())
        #expect(turns.isEmpty)
    }

    @Test("Chronological order")
    func chronologicalOrder() throws {
        let assistant = makeAssistantLine(messageId: "msg_1", contentBlocks: [
            "{\"type\": \"text\", \"text\": \"response\"}"
        ], timestamp: "2026-01-01T00:00:02.000Z")
        let user = makeUserLine(content: "\"question\"", timestamp: "2026-01-01T00:00:01.000Z")

        // Put assistant first in the file, but user has earlier timestamp
        let jsonl = [assistant, user].joined(separator: "\n")
        let turns = try TranscriptParser.parse(data: Data(jsonl.utf8))

        #expect(turns.count == 2)
        if case .userMessage = turns[0] {} else { Issue.record("Expected user first") }
        if case .assistantMessage = turns[1] {} else { Issue.record("Expected assistant second") }
    }

    @Test("Multiple assistant messages stay separate")
    func separateAssistantMessages() throws {
        let line1 = makeAssistantLine(messageId: "msg_1", contentBlocks: [
            "{\"type\": \"text\", \"text\": \"first\"}"
        ], timestamp: "2026-01-01T00:00:01.000Z")
        let line2 = makeAssistantLine(messageId: "msg_2", contentBlocks: [
            "{\"type\": \"text\", \"text\": \"second\"}"
        ], timestamp: "2026-01-01T00:00:02.000Z")

        let jsonl = [line1, line2].joined(separator: "\n")
        let turns = try TranscriptParser.parse(data: Data(jsonl.utf8))

        #expect(turns.count == 2)
    }

    // MARK: - Codex parsing

    @Test("Parses Codex transcript with user and assistant turns")
    func parsesCodexTranscript() throws {
        let lines = [
            // Developer message — should be skipped
            """
            {"timestamp":"2026-03-18T01:15:14.280Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>..."}]}}
            """,
            // User message
            """
            {"timestamp":"2026-03-18T01:15:14.281Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"study the cancellation workflow"}]}}
            """,
            // Assistant message
            """
            {"timestamp":"2026-03-18T01:15:15.100Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I'm reviewing the repo evidence for cancellations."}],"phase":"commentary"}}
            """,
            // session_meta — should be skipped
            """
            {"timestamp":"2026-03-18T01:15:13.000Z","type":"session_meta","payload":{"model":"o4-mini"}}
            """,
            // reasoning — should be skipped
            """
            {"timestamp":"2026-03-18T01:15:14.500Z","type":"response_item","payload":{"type":"reasoning","content":[]}}
            """,
        ]
        let jsonl = lines.joined(separator: "\n")
        let turns = try TranscriptParser.parseCodex(data: Data(jsonl.utf8))

        #expect(turns.count == 2)
        if case .userMessage(let text, _) = turns[0] {
            #expect(text == "study the cancellation workflow")
        } else {
            Issue.record("Expected userMessage first, got \(turns[0])")
        }
        if case .assistantMessage(let text, let tools, _) = turns[1] {
            #expect(text == "I'm reviewing the repo evidence for cancellations.")
            #expect(tools.isEmpty)
        } else {
            Issue.record("Expected assistantMessage second, got \(turns[1])")
        }
    }

    @Test("Codex parser handles timestamps without fractional seconds")
    func codexTimestampsWithoutFractional() throws {
        let lines = [
            """
            {"timestamp":"2026-03-18T01:15:14Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}
            """,
            """
            {"timestamp":"2026-03-18T01:15:15Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi there"}]}}
            """,
        ]
        let jsonl = lines.joined(separator: "\n")
        let turns = try TranscriptParser.parseCodex(data: Data(jsonl.utf8))

        #expect(turns.count == 2)
        // Verify timestamps are NOT distantPast (the bug was that timestamps without
        // fractional seconds failed to parse, falling back to Date.distantPast)
        #expect(turns[0].timestamp != Date.distantPast)
        #expect(turns[1].timestamp != Date.distantPast)
        #expect(turns[0].timestamp < turns[1].timestamp)
    }

    @Test("Codex parser skips developer messages")
    func codexSkipsDeveloper() throws {
        let jsonl = """
        {"timestamp":"2026-03-18T01:15:14.280Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"system instructions here"}]}}
        """
        let turns = try TranscriptParser.parseCodex(data: Data(jsonl.utf8))
        #expect(turns.isEmpty)
    }

    // MARK: - Tool input capture

    @Test("Captures tool input as JSON string for Claude tool_use")
    func capturesToolInputJSON() throws {
        let line = makeAssistantLine(messageId: "msg_1", contentBlocks: [
            "{\"type\": \"tool_use\", \"id\": \"t1\", \"name\": \"Read\", \"input\": {\"file_path\": \"/tmp/foo.swift\"}}"
        ])
        let turns = try TranscriptParser.parse(data: Data(line.utf8))

        #expect(turns.count == 1)
        guard case .assistantMessage(_, let tools, _) = turns[0] else {
            Issue.record("Expected assistantMessage")
            return
        }
        #expect(tools.count == 1)
        let inputJSON = tools[0].inputJSON
        #expect(inputJSON != nil)

        // Re-parse the JSON to compare semantically rather than by string match.
        guard let json = inputJSON,
              let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Expected inputJSON to decode to a dictionary")
            return
        }
        #expect(dict["file_path"] as? String == "/tmp/foo.swift")
    }

    @Test("Tool call inputJSON is nil when input absent")
    func toolInputAbsent() throws {
        let line = makeAssistantLine(messageId: "msg_1", contentBlocks: [
            "{\"type\": \"tool_use\", \"id\": \"t1\", \"name\": \"Read\"}"
        ])
        let turns = try TranscriptParser.parse(data: Data(line.utf8))

        #expect(turns.count == 1)
        guard case .assistantMessage(_, let tools, _) = turns[0] else {
            Issue.record("Expected assistantMessage")
            return
        }
        #expect(tools.count == 1)
        #expect(tools[0].inputJSON == nil)
    }

    @Test("Codex function_call captures input")
    func codexFunctionCallCapturesInput() throws {
        let jsonl = """
        {"timestamp":"2026-03-18T01:15:14.280Z","type":"response_item","payload":{"type":"function_call","name":"shell","input":{"command":"ls"}}}
        """
        let turns = try TranscriptParser.parseCodex(data: Data(jsonl.utf8))

        #expect(turns.count == 1)
        guard case .assistantMessage(_, let tools, _) = turns[0] else {
            Issue.record("Expected assistantMessage")
            return
        }
        #expect(tools.count == 1)
        #expect(tools[0].toolName == "shell")

        guard let json = tools[0].inputJSON,
              let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Expected inputJSON to decode to a dictionary")
            return
        }
        #expect(dict["command"] as? String == "ls")
    }

    // MARK: - Helpers

    private func makeSession(conversationId: String? = nil, directory: String = "/tmp") -> Session {
        Session(
            id: "test-id",
            conversationId: conversationId,
            tool: .claude,
            directory: directory,
            launchDirectory: nil,
            hostWorkspaceFolder: nil,
            lastAsk: nil,
            lastReply: nil,
            status: .idle,
            pid: 1234,
            hostAppBundleId: nil,
            hostAppName: nil,
            windowId: nil,
            transcriptPath: nil,
            startedAt: Date(),
            updatedAt: Date()
        )
    }

    private func makeUserLine(content: String, timestamp: String = "2026-01-01T00:00:00.000Z") -> String {
        """
        {"type": "user", "message": {"role": "user", "content": \(content)}, "timestamp": "\(timestamp)", "uuid": "u-\(UUID().uuidString)"}
        """
    }

    private func makeAssistantLine(messageId: String, contentBlocks: [String], timestamp: String = "2026-01-01T00:00:00.000Z") -> String {
        let blocksStr = contentBlocks.joined(separator: ", ")
        return """
        {"type": "assistant", "message": {"id": "\(messageId)", "role": "assistant", "content": [\(blocksStr)]}, "timestamp": "\(timestamp)", "uuid": "a-\(UUID().uuidString)"}
        """
    }

    @Test("transcriptURL from raw fields returns correct path")
    func transcriptURLFromRawFields() {
        let url = TranscriptParser.transcriptURL(conversationId: "abc-123", directory: "/Users/foo/project")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expected = home.appendingPathComponent(".claude/projects/-Users-foo-project/abc-123.jsonl")
        #expect(url == expected)
    }

    // MARK: - resolveExistingTranscript

    /// Build a Session with explicit `transcriptPath` so the existence-probe
    /// chain in `resolveExistingTranscript` can be exercised.
    private func makeSessionWithTranscriptPath(
        conversationId: String?,
        directory: String,
        transcriptPath: String?
    ) -> Session {
        Session(
            id: "test-id",
            conversationId: conversationId,
            tool: .claude,
            directory: directory,
            launchDirectory: nil,
            hostWorkspaceFolder: nil,
            lastAsk: nil,
            lastReply: nil,
            status: .idle,
            pid: 1234,
            hostAppBundleId: nil,
            hostAppName: nil,
            windowId: nil,
            transcriptPath: transcriptPath,
            startedAt: Date(),
            updatedAt: Date()
        )
    }

    @Test("findTranscript locates jsonl by conversation id across project dirs")
    func findTranscriptLocatesByConversationId() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("transcript-find-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        let projectDir = root.appendingPathComponent("-Users-foo-some-other-place")
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let convId = UUID().uuidString
        let file = projectDir.appendingPathComponent("\(convId).jsonl")
        try Data("{}".utf8).write(to: file)

        // `contentsOfDirectory(at:)` canonicalizes /var → /private/var on
        // macOS, so compare standardized URLs rather than raw paths.
        let found = TranscriptParser.findTranscript(conversationId: convId, in: root)
        #expect(found?.standardizedFileURL == file.standardizedFileURL)
    }

    @Test("findTranscript returns nil when projects root is absent")
    func findTranscriptMissingRoot() {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        #expect(TranscriptParser.findTranscript(conversationId: "anything", in: nonexistent) == nil)
    }

    @Test("findTranscript returns nil when no matching jsonl exists")
    func findTranscriptNoMatch() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("transcript-find-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        let projectDir = root.appendingPathComponent("-Users-foo-bar")
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        // A jsonl file for a *different* conversation id.
        let otherFile = projectDir.appendingPathComponent("\(UUID().uuidString).jsonl")
        try Data("{}".utf8).write(to: otherFile)

        #expect(TranscriptParser.findTranscript(conversationId: UUID().uuidString, in: root) == nil)
    }

    @Test("resolveExistingTranscript prefers stored transcriptPath when it exists")
    func resolveUsesStoredPath() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("transcript-resolve-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let stored = dir.appendingPathComponent("stored.jsonl")
        try Data("{}".utf8).write(to: stored)

        let session = makeSessionWithTranscriptPath(
            conversationId: "abc-123",
            directory: "/Users/foo/bar",
            transcriptPath: stored.path
        )
        #expect(TranscriptParser.resolveExistingTranscript(for: session)?.path == stored.path)
    }

    @Test("resolveExistingTranscript returns nil when session has no conversation id and stored path is missing")
    func resolveReturnsNilWhenStoredMissingAndNoConvId() {
        let session = makeSessionWithTranscriptPath(
            conversationId: nil,
            directory: "/Users/foo/bar",
            transcriptPath: "/does/not/exist.jsonl"
        )
        #expect(TranscriptParser.resolveExistingTranscript(for: session) == nil)
    }

    @Test("resolveExistingTranscript falls back to computed path (leg B)")
    func resolveLegBComputedPathHit() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("transcript-resolve-legb-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        // Directory string the resolver will encode to find the computed file.
        let sessionDir = "/Users/foo/myproject"
        let encoded = TranscriptParser.encodePath(sessionDir)
        let convId = UUID().uuidString
        let projectDir = root.appendingPathComponent(encoded)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let computed = projectDir.appendingPathComponent("\(convId).jsonl")
        try Data("{}".utf8).write(to: computed)

        let session = makeSessionWithTranscriptPath(
            conversationId: convId,
            directory: sessionDir,
            transcriptPath: "/does/not/exist.jsonl"  // forces leg A to fail
        )

        let resolved = TranscriptParser.resolveExistingTranscript(for: session, projectsRoot: root)
        #expect(resolved?.standardizedFileURL == computed.standardizedFileURL)
    }

    @Test("resolveExistingTranscript falls back to glob (leg C)")
    func resolveLegCGlobHit() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("transcript-resolve-legc-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        // The encoded session dir doesn't have a file in it — but a different
        // project dir DOES contain the convId.jsonl. This mirrors the
        // mid-session-cd / worktree-entry scenario.
        let sessionDir = "/Users/foo/seshctl/.claude/worktrees/julo+myname"
        try fm.createDirectory(
            at: root.appendingPathComponent(TranscriptParser.encodePath(sessionDir)),
            withIntermediateDirectories: true
        )
        let convId = UUID().uuidString
        let actualProjectDir = root.appendingPathComponent("-Users-foo-seshctl")
        try fm.createDirectory(at: actualProjectDir, withIntermediateDirectories: true)
        let actualFile = actualProjectDir.appendingPathComponent("\(convId).jsonl")
        try Data("{}".utf8).write(to: actualFile)

        let session = makeSessionWithTranscriptPath(
            conversationId: convId,
            directory: sessionDir,
            transcriptPath: nil  // leg A skipped; leg B misses (no file in encoded dir); leg C hits
        )

        let resolved = TranscriptParser.resolveExistingTranscript(for: session, projectsRoot: root)
        #expect(resolved?.standardizedFileURL == actualFile.standardizedFileURL)
    }

    @Test("resolveExistingTranscript by conversationId+directory walks legs B and C")
    func resolveByConversationIdLegsBAndC() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("transcript-resolve-recall-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        // Leg B hit: file at the computed encoded path.
        let convB = UUID().uuidString
        let dirB = "/Users/foo/legb"
        let projectB = root.appendingPathComponent(TranscriptParser.encodePath(dirB))
        try fm.createDirectory(at: projectB, withIntermediateDirectories: true)
        let fileB = projectB.appendingPathComponent("\(convB).jsonl")
        try Data("{}".utf8).write(to: fileB)

        let resolvedB = TranscriptParser.resolveExistingTranscript(
            conversationId: convB, directory: dirB, projectsRoot: root
        )
        #expect(resolvedB?.standardizedFileURL == fileB.standardizedFileURL)

        // Leg C hit: file lives under a *different* project dir than what
        // `encodePath(directory)` produces. Stand-in for the recall row
        // whose `.project` points at a worktree subdir, while Claude wrote
        // the file under the parent repo.
        let convC = UUID().uuidString
        let dirC = "/Users/foo/seshctl/.claude/worktrees/julo+somebranch"
        try fm.createDirectory(
            at: root.appendingPathComponent(TranscriptParser.encodePath(dirC)),
            withIntermediateDirectories: true
        )
        let actualC = root.appendingPathComponent("-Users-foo-seshctl")
        try fm.createDirectory(at: actualC, withIntermediateDirectories: true)
        let fileC = actualC.appendingPathComponent("\(convC).jsonl")
        try Data("{}".utf8).write(to: fileC)

        let resolvedC = TranscriptParser.resolveExistingTranscript(
            conversationId: convC, directory: dirC, projectsRoot: root
        )
        #expect(resolvedC?.standardizedFileURL == fileC.standardizedFileURL)
    }

    // MARK: - ConversationTurn.id

    @Test("Same timestamp different text produces different IDs")
    func sameTimestampDifferentText() {
        let ts = Date(timeIntervalSince1970: 1000)
        let turn1 = ConversationTurn.userMessage(text: "hello", timestamp: ts)
        let turn2 = ConversationTurn.userMessage(text: "world", timestamp: ts)
        #expect(turn1.id != turn2.id)
    }

    @Test("Same turn produces stable ID across calls")
    func stableId() {
        let turn = ConversationTurn.userMessage(text: "hello", timestamp: Date(timeIntervalSince1970: 1000))
        let id1 = turn.id
        let id2 = turn.id
        #expect(id1 == id2)
    }

    @Test("Same text same timestamp produces same ID")
    func identicalTurnsSameId() {
        let ts = Date(timeIntervalSince1970: 1000)
        let turn1 = ConversationTurn.userMessage(text: "hello", timestamp: ts)
        let turn2 = ConversationTurn.userMessage(text: "hello", timestamp: ts)
        #expect(turn1.id == turn2.id)
    }

    // MARK: - Away summary (system/away_summary)

    @Test("away_summary record emits an awaySummary turn")
    func awaySummaryRecordEmitsTurn() throws {
        let line = """
        {"type":"system","subtype":"away_summary","content":"Shipped two PRs to main today: #31 and #32. (disable recaps in /config)","timestamp":"2026-05-06T17:48:04.022Z","sessionId":"abc","cwd":"/work"}
        """
        let turns = try TranscriptParser.parse(data: Data(line.utf8))
        #expect(turns.count == 1)
        guard case .awaySummary(let text, let ts) = turns[0] else {
            Issue.record("Expected awaySummary, got \(turns[0])")
            return
        }
        #expect(text == "Shipped two PRs to main today: #31 and #32.")
        #expect(ts != Date.distantPast)
    }

    @Test("away_summary strips the (disable recaps in /config) hint")
    func awaySummaryStripsRecapHint() throws {
        let line = """
        {"type":"system","subtype":"away_summary","content":"All clear.   (disable recaps in /config)","timestamp":"2026-05-06T17:48:04.022Z","sessionId":"abc"}
        """
        let turns = try TranscriptParser.parse(data: Data(line.utf8))
        #expect(turns.count == 1)
        guard case .awaySummary(let text, _) = turns[0] else {
            Issue.record("Expected awaySummary")
            return
        }
        #expect(text == "All clear.")
    }

    @Test("away_summary whose content is only the hint is skipped")
    func awaySummaryWithEmptyContentIsSkipped() throws {
        let onlyHint = """
        {"type":"system","subtype":"away_summary","content":"(disable recaps in /config)","timestamp":"2026-05-06T17:48:04.022Z","sessionId":"abc"}
        """
        let emptyString = """
        {"type":"system","subtype":"away_summary","content":"","timestamp":"2026-05-06T17:48:05.022Z","sessionId":"abc"}
        """
        let whitespaceOnly = """
        {"type":"system","subtype":"away_summary","content":"   \\n  ","timestamp":"2026-05-06T17:48:06.022Z","sessionId":"abc"}
        """
        let jsonl = [onlyHint, emptyString, whitespaceOnly].joined(separator: "\n")
        let turns = try TranscriptParser.parse(data: Data(jsonl.utf8))
        #expect(turns.isEmpty)
    }

    @Test("away_summary interleaves chronologically with user/assistant turns")
    func awaySummaryInterleavesChronologically() throws {
        let away1 = """
        {"type":"system","subtype":"away_summary","content":"recap one (disable recaps in /config)","timestamp":"2026-01-01T00:00:02.000Z","sessionId":"abc"}
        """
        let user1 = makeUserLine(content: "\"first ask\"", timestamp: "2026-01-01T00:00:01.000Z")
        let assistant1 = makeAssistantLine(messageId: "msg_1", contentBlocks: [
            "{\"type\": \"text\", \"text\": \"reply\"}"
        ], timestamp: "2026-01-01T00:00:03.000Z")
        let user2 = makeUserLine(content: "\"next ask\"", timestamp: "2026-01-01T00:00:04.000Z")

        // File order is intentionally scrambled relative to timestamps.
        let jsonl = [assistant1, away1, user2, user1].joined(separator: "\n")
        let turns = try TranscriptParser.parse(data: Data(jsonl.utf8))

        #expect(turns.count == 4)
        if case .userMessage(let t, _) = turns[0] { #expect(t == "first ask") } else { Issue.record("turns[0] should be user") }
        if case .awaySummary(let t, _) = turns[1] { #expect(t == "recap one") } else { Issue.record("turns[1] should be awaySummary") }
        if case .assistantMessage = turns[2] {} else { Issue.record("turns[2] should be assistant") }
        if case .userMessage(let t, _) = turns[3] { #expect(t == "next ask") } else { Issue.record("turns[3] should be user") }
    }

    @Test("Other system subtypes are still ignored")
    func otherSystemSubtypesStillIgnored() throws {
        let bridge = """
        {"type":"system","subtype":"bridge_status","content":"bridge up","timestamp":"2026-01-01T00:00:01.000Z"}
        """
        let duration = """
        {"type":"system","subtype":"turn_duration","content":"42ms","timestamp":"2026-01-01T00:00:02.000Z"}
        """
        let plainSystem = """
        {"type":"system","content":"no subtype","timestamp":"2026-01-01T00:00:03.000Z"}
        """
        let user = makeUserLine(content: "\"only me\"", timestamp: "2026-01-01T00:00:04.000Z")

        let jsonl = [bridge, duration, plainSystem, user].joined(separator: "\n")
        let turns = try TranscriptParser.parse(data: Data(jsonl.utf8))

        #expect(turns.count == 1)
        if case .userMessage(let text, _) = turns[0] {
            #expect(text == "only me")
        } else {
            Issue.record("Expected single user turn")
        }
    }

    @Test("Codex event_msg tool branch captures name and input")
    func codexEventMsgToolCapturesInput() throws {
        let line = """
        {"type":"event_msg","timestamp":"2026-01-01T00:00:00.000Z","payload":{"type":"tool_started","tool_name":"shell","input":{"command":"ls"}}}
        """
        let turns = try TranscriptParser.parseCodex(data: Data(line.utf8))
        #expect(turns.count == 1)
        guard case .assistantMessage(_, let calls, _) = turns[0], let call = calls.first else {
            Issue.record("expected assistantMessage with one tool call")
            return
        }
        #expect(call.toolName == "shell")
        guard let json = call.inputJSON,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("expected inputJSON to decode as dict")
            return
        }
        #expect(dict["command"] as? String == "ls")
    }
}

/// Pi writes `<home>/sessions/--<encoded-cwd>--/<ts>_<uuid>.jsonl`, where
/// `<home>` is `~/.agents` on current versions and `~/.pi/agent` on older ones.
/// These fixtures mirror the real on-disk shape: a `session` header line, then
/// `message` records whose `message.content` blocks are `text` / `thinking` /
/// `toolCall`.
///
/// Note this format lives *beside* Codex's in the same `sessions/` folder when
/// `CODEX_HOME` points at `~/.agents` — Codex's `rollout-*.jsonl` files use the
/// unrelated `response_item` shape that `parseCodex` handles. The two are told
/// apart by path shape, not by directory or by the `provider` field (Pi records
/// `provider: "openai-codex"` when Codex is merely its model provider).
@Suite("TranscriptParser — Pi")
struct TranscriptParserPiTests {

    private func parse(_ lines: [String]) throws -> [ConversationTurn] {
        let data = Data(lines.joined(separator: "\n").utf8)
        return try TranscriptParser.parsePi(data: data)
    }

    private let sessionHeader = #"{"type":"session","version":3,"id":"019ea68d","timestamp":"2026-06-08T09:26:04.018Z","cwd":"/tmp/repo"}"#

    private func message(role: String, content: String, at timestamp: String) -> String {
        #"{"type":"message","id":"a1","parentId":"b1","timestamp":"\#(timestamp)","message":{"role":"\#(role)","content":\#(content)}}"#
    }

    @Test("Parses a user turn from a Pi message record")
    func parsesUserTurn() throws {
        let turns = try parse([
            sessionHeader,
            message(role: "user", content: #"[{"type":"text","text":"can skills be lazy loaded?"}]"#, at: "2026-06-08T09:26:47.549Z"),
        ])
        #expect(turns.count == 1)
        guard case .userMessage(let text, _) = turns[0] else {
            Issue.record("expected userMessage, got \(turns[0])")
            return
        }
        #expect(text == "can skills be lazy loaded?")
    }

    @Test("Parses assistant text and toolCall blocks into one turn")
    func parsesAssistantTurn() throws {
        let content = #"""
        [{"type":"text","text":"Checking the repo state."},{"type":"toolCall","id":"call_1|fc_1","name":"bash","arguments":{"command":"git status --short","timeout":30}}]
        """#
        let turns = try parse([
            sessionHeader,
            message(role: "assistant", content: content, at: "2026-06-08T09:26:50.000Z"),
        ])
        #expect(turns.count == 1)
        guard case .assistantMessage(let text, let toolCalls, _) = turns[0] else {
            Issue.record("expected assistantMessage, got \(turns[0])")
            return
        }
        #expect(text == "Checking the repo state.")
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].toolName == "bash")
        // v3 names the payload `arguments`; legacy used `input`.
        let json = try #require(toolCalls[0].inputJSON)
        #expect(json.contains("git status --short"))
    }

    @Test("Drops thinking blocks from assistant turns")
    func dropsThinking() throws {
        let content = #"""
        [{"type":"thinking","thinking":"The user wants X, so I should Y.","thinkingSignature":"sig"},{"type":"text","text":"Done."}]
        """#
        let turns = try parse([
            sessionHeader,
            message(role: "assistant", content: content, at: "2026-06-08T09:27:00.000Z"),
        ])
        #expect(turns.count == 1)
        guard case .assistantMessage(let text, _, _) = turns[0] else {
            Issue.record("expected assistantMessage, got \(turns[0])")
            return
        }
        #expect(text == "Done.")
        #expect(!text.contains("The user wants X"))
    }

    @Test("Emits no turn for a thinking-only assistant message")
    func thinkingOnlyProducesNoTurn() throws {
        let content = #"[{"type":"thinking","thinking":"Still reasoning.","thinkingSignature":"sig"}]"#
        let turns = try parse([
            sessionHeader,
            message(role: "assistant", content: content, at: "2026-06-08T09:27:05.000Z"),
        ])
        #expect(turns.isEmpty)
    }

    @Test("Skips toolResult-role records")
    func skipsToolResults() throws {
        let turns = try parse([
            sessionHeader,
            message(role: "toolResult", content: #"[{"type":"text","text":"origin\tgit@github.com:foo/bar.git (fetch)"}]"#, at: "2026-06-08T09:27:10.000Z"),
        ])
        #expect(turns.isEmpty)
    }

    @Test("Filters injected skill context out of user turns")
    func filtersInjectedContext() throws {
        let injected = #"[{"type":"text","text":"<skill name=\"tom-review\" location=\"/Users/x/.agents/skills/tom-review/SKILL.md\">"},{"type":"text","text":"well, do we need to add tests?"}]"#
        let turns = try parse([
            sessionHeader,
            message(role: "user", content: injected, at: "2026-06-08T09:27:20.000Z"),
        ])
        #expect(turns.count == 1)
        guard case .userMessage(let text, _) = turns[0] else {
            Issue.record("expected userMessage, got \(turns[0])")
            return
        }
        #expect(text == "well, do we need to add tests?")
    }

    @Test("Ignores the session header and unknown record types")
    func ignoresNonMessageRecords() throws {
        let turns = try parse([
            sessionHeader,
            #"{"type":"model_change","timestamp":"2026-06-08T09:26:10.000Z","model":"gpt-5"}"#,
            #"{"type":"thinking_level_change","timestamp":"2026-06-08T09:26:11.000Z","level":"high"}"#,
        ])
        #expect(turns.isEmpty)
    }

    @Test("Orders Pi turns chronologically")
    func ordersChronologically() throws {
        let turns = try parse([
            sessionHeader,
            message(role: "assistant", content: #"[{"type":"text","text":"second"}]"#, at: "2026-06-08T09:30:00.000Z"),
            message(role: "user", content: #"[{"type":"text","text":"first"}]"#, at: "2026-06-08T09:20:00.000Z"),
        ])
        #expect(turns.count == 2)
        guard case .userMessage(let firstText, _) = turns[0] else {
            Issue.record("expected userMessage first, got \(turns[0])")
            return
        }
        #expect(firstText == "first")
    }

    @Test("Codex response_item records are not Pi turns")
    func codexFormatIsNotParsedAsPi() throws {
        // Guards the split: these two formats can share one sessions/ folder,
        // so each parser must ignore the other's records rather than
        // half-reading them.
        let codex = #"{"type":"response_item","timestamp":"2026-06-08T09:26:47.549Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"codex prompt"}]}}"#
        #expect(try parse([codex]).isEmpty)

        let viaCodex = try TranscriptParser.parseCodex(data: Data(codex.utf8))
        #expect(viaCodex.count == 1)
    }

    @Test("parsesTranscripts marks exactly the tools with a parser")
    func parsesTranscriptsMatchesDispatch() {
        for tool in SessionTool.allCases {
            let turns = (try? TranscriptParser.parse(data: Data(), tool: tool)) ?? []
            #expect(turns.isEmpty)  // empty input always yields nothing
            // The flag must agree with the dispatch arm, or callers that skip
            // on it will silently drop a tool that does have a parser.
            switch tool {
            case .claude, .codex, .pi:
                #expect(TranscriptParser.parsesTranscripts(tool))
            case .gemini, .cursor:
                #expect(!TranscriptParser.parsesTranscripts(tool))
            }
        }
    }
}
