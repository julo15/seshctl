import Foundation
import Testing

@testable import SeshctlCore

@Suite("Database")
struct DatabaseTests {
    @Test("Creates database and runs migrations")
    func createDatabase() throws {
        let db = try SeshctlDatabase.temporary()
        let sessions = try db.listSessions()
        #expect(sessions.isEmpty)
    }

    @Test("Start creates a session")
    func startSession() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp/test", pid: 1234)

        #expect(session.tool == .claude)
        #expect(session.directory == "/tmp/test")
        #expect(session.pid == 1234)
        #expect(session.status == .idle)
        #expect(!session.id.isEmpty)
    }

    @Test("Start with conversation ID")
    func startWithConversationId() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(
            tool: .claude, directory: "/tmp", pid: 1234,
            conversationId: "conv-abc"
        )
        #expect(session.conversationId == "conv-abc")
    }

    @Test("Start ends existing active session for same pid+tool")
    func startEndsExisting() throws {
        let db = try SeshctlDatabase.temporary()
        let first = try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1234)
        let second = try db.startSession(tool: .claude, directory: "/tmp/b", pid: 1234)

        #expect(first.id != second.id)

        // First should now be completed
        let firstFetched = try db.getSession(id: first.id)
        #expect(firstFetched?.status == .completed)

        // Second should be active
        let secondFetched = try db.getSession(id: second.id)
        #expect(secondFetched?.status == .idle)
    }

    @Test("Start does not end sessions for different pid")
    func startDifferentPid() throws {
        let db = try SeshctlDatabase.temporary()
        let first = try db.startSession(tool: .claude, directory: "/tmp", pid: 1111)
        _ = try db.startSession(tool: .claude, directory: "/tmp", pid: 2222)

        let firstFetched = try db.getSession(id: first.id)
        #expect(firstFetched?.status == .idle)
    }

    @Test("Start does not end sessions for different tool")
    func startDifferentTool() throws {
        let db = try SeshctlDatabase.temporary()
        let first = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        _ = try db.startSession(tool: .gemini, directory: "/tmp", pid: 1234)

        let firstFetched = try db.getSession(id: first.id)
        #expect(firstFetched?.status == .idle)
    }

    @Test("Update modifies active session")
    func updateSession() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        let updated = try db.updateSession(
            pid: 1234, tool: .claude,
            ask: "hello world", status: .working
        )

        #expect(updated.lastAsk == "hello world")
        #expect(updated.status == .working)
    }

    @Test("Update truncates ask to 500 chars")
    func updateTruncatesAsk() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        let longAsk = String(repeating: "x", count: 1000)
        let updated = try db.updateSession(pid: 1234, tool: .claude, ask: longAsk)

        #expect(updated.lastAsk?.count == 500)
    }

    @Test("Update creates session if none exists (idempotent)")
    func updateCreatesSession() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.updateSession(
            pid: 9999, tool: .gemini,
            ask: "hello", status: .working
        )

        #expect(session.tool == .gemini)
        #expect(session.pid == 9999)
        #expect(session.lastAsk == "hello")
        #expect(session.status == .working)
    }

    @Test("End sets session to completed")
    func endSession() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        try db.endSession(pid: 1234, tool: .claude)

        let fetched = try db.getSession(id: session.id)
        #expect(fetched?.status == .completed)
    }

    @Test("End with canceled status")
    func endCanceled() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        try db.endSession(pid: 1234, tool: .claude, status: .canceled)

        let fetched = try db.getSession(id: session.id)
        #expect(fetched?.status == .canceled)
    }

    @Test("End on already-ended session is a no-op")
    func endAlreadyEnded() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        try db.endSession(pid: 1234, tool: .claude)
        // Should not throw
        try db.endSession(pid: 1234, tool: .claude)
    }

    @Test("List returns sessions ordered by updated_at DESC")
    func listOrder() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp/a", pid: 1111)
        try db.startSession(tool: .gemini, directory: "/tmp/b", pid: 2222)
        try db.startSession(tool: .codex, directory: "/tmp/c", pid: 3333)

        let sessions = try db.listSessions()
        #expect(sessions.count == 3)
        // Most recent first
        #expect(sessions[0].tool == .codex)
    }

    @Test("List filters by status")
    func listFilterStatus() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1111)
        try db.startSession(tool: .gemini, directory: "/tmp", pid: 2222)
        try db.endSession(pid: 2222, tool: .gemini)

        let idle = try db.listSessions(status: .idle)
        #expect(idle.count == 1)
        #expect(idle[0].tool == .claude)

        let completed = try db.listSessions(status: .completed)
        #expect(completed.count == 1)
        #expect(completed[0].tool == .gemini)
    }

    @Test("List filters by tool")
    func listFilterTool() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1111)
        try db.startSession(tool: .gemini, directory: "/tmp", pid: 2222)

        let claudeOnly = try db.listSessions(tool: .claude)
        #expect(claudeOnly.count == 1)
        #expect(claudeOnly[0].tool == .claude)
    }

    @Test("List respects limit")
    func listLimit() throws {
        let db = try SeshctlDatabase.temporary()
        for i in 1...5 {
            try db.startSession(tool: .claude, directory: "/tmp", pid: i)
        }

        let sessions = try db.listSessions(limit: 3)
        #expect(sessions.count == 3)
    }

    @Test("Show returns session by ID")
    func showSession() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        let fetched = try db.getSession(id: session.id)
        #expect(fetched?.id == session.id)
        #expect(fetched?.tool == .claude)
    }

    @Test("Show returns nil for unknown ID")
    func showUnknown() throws {
        let db = try SeshctlDatabase.temporary()
        let fetched = try db.getSession(id: "nonexistent")
        #expect(fetched == nil)
    }

    @Test("Multiple sessions can share a conversation ID")
    func conversationContinuity() throws {
        let db = try SeshctlDatabase.temporary()
        let first = try db.startSession(
            tool: .claude, directory: "/tmp", pid: 1111,
            conversationId: "conv-123"
        )
        try db.endSession(pid: 1111, tool: .claude)

        let second = try db.startSession(
            tool: .claude, directory: "/tmp", pid: 2222,
            conversationId: "conv-123"
        )

        #expect(first.conversationId == second.conversationId)
        #expect(first.id != second.id)
    }

    @Test("GC deletes old completed sessions")
    func gcDeletesOld() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        try db.endSession(pid: 1234, tool: .claude)

        // Negative olderThan puts the cutoff in the future, so everything is "old"
        let (deleted, _) = try db.gc(olderThan: -1)
        #expect(deleted == 1)

        let sessions = try db.listSessions()
        #expect(sessions.isEmpty)
    }

    @Test("GC marks stale sessions when PID is dead")
    func gcMarksStale() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 99999)

        let (_, markedStale) = try db.gc(isProcessAlive: { _ in false })
        #expect(markedStale == 1)

        let sessions = try db.listSessions(status: .stale)
        #expect(sessions.count == 1)
    }

    @Test("GC does not mark stale if PID is alive")
    func gcDoesNotMarkAlive() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        let (_, markedStale) = try db.gc(isProcessAlive: { _ in true })
        #expect(markedStale == 0)

        let sessions = try db.listSessions(status: .idle)
        #expect(sessions.count == 1)
    }

    @Test("Reap stales conversation-id row when host app quit")
    func reapStalesCursorWhenAppQuit() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(
            conversationId: "cursor-conv-1",
            tool: .cursor, directory: "/tmp",
            hostAppBundleId: "com.todesktop.230313mzl4w4u92",
            hostAppName: "Cursor"
        )

        let marked = try db.reapStaleSessions(
            isHostAppRunning: { _ in false }
        )
        #expect(marked == 1)

        let stale = try db.listSessions(status: .stale)
        #expect(stale.count == 1)
        #expect(stale.first?.tool == .cursor)
    }

    @Test("Reap leaves conversation-id row alone when host app running")
    func reapLeavesCursorWhenAppRunning() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(
            conversationId: "cursor-conv-1",
            tool: .cursor, directory: "/tmp",
            hostAppBundleId: "com.todesktop.230313mzl4w4u92",
            hostAppName: "Cursor"
        )

        let marked = try db.reapStaleSessions(
            isHostAppRunning: { _ in true }
        )
        #expect(marked == 0)

        let idle = try db.listSessions(status: .idle)
        #expect(idle.count == 1)
    }

    @Test("Reap leaves row alone when pid==nil and host bundle unknown")
    func reapLeavesRowWithNoSignal() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(
            conversationId: "conv-no-host",
            tool: .cursor, directory: "/tmp",
            hostAppBundleId: nil, hostAppName: nil
        )

        let marked = try db.reapStaleSessions(
            isHostAppRunning: { _ in false }
        )
        #expect(marked == 0)
    }

    @Test("Reap consults PID first when both signals present")
    func reapPidShortCircuitsHostBranch() throws {
        let db = try SeshctlDatabase.temporary()
        // PID-keyed row that also happens to carry a host bundle id.
        try db.startSession(
            tool: .claude, directory: "/tmp", pid: 99999,
            hostAppBundleId: "com.apple.Terminal", hostAppName: "Terminal"
        )

        // PID dead, host bundle "running" — reap because PID branch fires first.
        let marked = try db.reapStaleSessions(
            isProcessAlive: { _ in false },
            isHostAppRunning: { _ in true }
        )
        #expect(marked == 1)
    }

    @Test("GC marks conversation-id row stale when host app quit")
    func gcMarksCursorStaleWhenAppQuit() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(
            conversationId: "cursor-conv-gc",
            tool: .cursor, directory: "/tmp",
            hostAppBundleId: "com.todesktop.230313mzl4w4u92",
            hostAppName: "Cursor"
        )

        let (_, markedStale) = try db.gc(isHostAppRunning: { _ in false })
        #expect(markedStale == 1)
    }

    @Test("Status transitions: idle → working → idle")
    func statusTransitions() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        var session = try db.updateSession(pid: 1234, tool: .claude, status: .working)
        #expect(session.status == .working)

        session = try db.updateSession(pid: 1234, tool: .claude, status: .idle)
        #expect(session.status == .idle)
    }

    @Test("Status transitions: working → waiting → working")
    func waitingStatusTransitions() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        var session = try db.updateSession(pid: 1234, tool: .claude, status: .working)
        #expect(session.status == .working)

        session = try db.updateSession(pid: 1234, tool: .claude, status: .waiting)
        #expect(session.status == .waiting)

        session = try db.updateSession(pid: 1234, tool: .claude, status: .working)
        #expect(session.status == .working)
    }

    @Test("Waiting counts as active")
    func waitingIsActive() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        try db.updateSession(pid: 1234, tool: .claude, status: .working)
        let session = try db.updateSession(pid: 1234, tool: .claude, status: .waiting)

        #expect(session.isActive)
    }

    @Test("Waiting sessions appear in active session lookup")
    func waitingInActiveSessionLookup() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        try db.updateSession(pid: 1234, tool: .claude, status: .working)
        try db.updateSession(pid: 1234, tool: .claude, status: .waiting)

        let found = try db.findActiveSession(pid: 1234, tool: .claude)
        #expect(found != nil)
        #expect(found?.status == .waiting)
    }

    @Test("Late Notification ignored when session is idle (Stop fired first)")
    func waitingIgnoredWhenIdle() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        // Simulate: working → idle (Stop) → waiting (stale Notification)
        try db.updateSession(pid: 1234, tool: .claude, status: .working)
        try db.updateSession(pid: 1234, tool: .claude, status: .idle)
        let session = try db.updateSession(pid: 1234, tool: .claude, status: .waiting)

        // Should remain idle — late Notification is stale
        #expect(session.status == .idle)
    }

    @Test("PreToolUse resumes working from waiting (ask answered)")
    func preToolUseResumesFromWaiting() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        // Simulate: working → waiting (Notification) → working (PreToolUse)
        try db.updateSession(pid: 1234, tool: .claude, status: .working)
        try db.updateSession(pid: 1234, tool: .claude, status: .waiting)
        let session = try db.updateSession(pid: 1234, tool: .claude, status: .working)

        #expect(session.status == .working)
    }

    @Test("Full ask cycle: working → waiting → working → idle")
    func fullAskCycle() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        // UserPromptSubmit → working
        var session = try db.updateSession(pid: 1234, tool: .claude, status: .working)
        #expect(session.status == .working)

        // Notification → waiting (Claude asks user)
        session = try db.updateSession(pid: 1234, tool: .claude, status: .waiting)
        #expect(session.status == .waiting)

        // PreToolUse → working (user answered, Claude resumes)
        session = try db.updateSession(pid: 1234, tool: .claude, status: .working)
        #expect(session.status == .working)

        // Stop → idle
        session = try db.updateSession(pid: 1234, tool: .claude, status: .idle)
        #expect(session.status == .idle)
    }

    @Test("Skip-git update preserves existing git fields")
    func skipGitPreservesFields() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        // Set git fields via normal update
        try db.updateSession(pid: 1234, tool: .claude, gitRepoName: "myrepo", gitBranch: "main")

        // Status-only update with nil git fields (simulates --skip-git)
        let session = try db.updateSession(pid: 1234, tool: .claude, status: .working)

        #expect(session.gitRepoName == "myrepo")
        #expect(session.gitBranch == "main")
    }

    @Test("Waiting transition ignored from completed session")
    func waitingIgnoredWhenCompleted() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        try db.endSession(pid: 1234, tool: .claude)

        // Verify the session is completed
        let fetched = try db.getSession(id: session.id)
        #expect(fetched?.status == .completed)

        // A late Notification creates a new session (no active one to update)
        let created = try db.updateSession(pid: 1234, tool: .claude, status: .waiting)
        #expect(created.id != session.id)
        #expect(created.status == .waiting)

        // Original session unchanged
        let original = try db.getSession(id: session.id)
        #expect(original?.status == .completed)
    }

    @Test("findActiveSession returns the right session")
    func findActiveSession() throws {
        let db = try SeshctlDatabase.temporary()
        let created = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        let found = try db.findActiveSession(pid: 1234, tool: .claude)
        #expect(found?.id == created.id)

        let notFound = try db.findActiveSession(pid: 1234, tool: .gemini)
        #expect(notFound == nil)
    }

    // MARK: - Unread (markSessionRead) Tests

    @Test("New sessions start as read")
    func newSessionStartsAsRead() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)
        #expect(session.lastReadAt != nil)
        #expect(session.lastReadAt == session.updatedAt)
    }

    @Test("markSessionRead sets last_read_at")
    func markSessionRead() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        try db.markSessionRead(id: session.id)

        let fetched = try db.getSession(id: session.id)
        #expect(fetched?.lastReadAt != nil)
    }

    // MARK: - Git Context Tests

    @Test("Start stores git context")
    func startStoresGitContext() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(
            tool: .claude, directory: "/tmp/test", pid: 1234,
            gitRepoName: "seshctl", gitBranch: "main"
        )

        #expect(session.gitRepoName == "seshctl")
        #expect(session.gitBranch == "main")

        let fetched = try db.getSession(id: session.id)
        #expect(fetched?.gitRepoName == "seshctl")
        #expect(fetched?.gitBranch == "main")
    }

    @Test("Update stores git context")
    func updateStoresGitContext() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        let updated = try db.updateSession(
            pid: 1234, tool: .claude,
            gitRepoName: "seshctl", gitBranch: "feat-auth"
        )

        #expect(updated.gitRepoName == "seshctl")
        #expect(updated.gitBranch == "feat-auth")

        let fetched = try db.getSession(id: updated.id)
        #expect(fetched?.gitRepoName == "seshctl")
        #expect(fetched?.gitBranch == "feat-auth")
    }

    @Test("Start with nil git context")
    func startWithNilGitContext() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(tool: .claude, directory: "/tmp", pid: 1234)

        #expect(session.gitRepoName == nil)
        #expect(session.gitBranch == nil)
    }

    // MARK: - Launch Args Tests

    @Test("startSession stores launch args")
    func startSessionStoresLaunchArgs() throws {
        let db = try SeshctlDatabase.temporary()
        _ = try db.startSession(
            tool: .claude, directory: "/tmp/test", pid: 1234,
            launchArgs: "--dangerously-skip-permissions"
        )

        // Re-fetch to verify it was persisted
        let fetched = try db.findActiveSession(pid: 1234, tool: .claude)
        #expect(fetched?.launchArgs == "--dangerously-skip-permissions")
    }

    @Test("startSession with nil launch args")
    func startSessionNilLaunchArgs() throws {
        let db = try SeshctlDatabase.temporary()
        _ = try db.startSession(
            tool: .claude, directory: "/tmp/test", pid: 1234
        )

        let fetched = try db.findActiveSession(pid: 1234, tool: .claude)
        #expect(fetched?.launchArgs == nil)
    }

    @Test("startSession with empty launch args stores nil")
    func startSessionEmptyLaunchArgs() throws {
        let db = try SeshctlDatabase.temporary()
        _ = try db.startSession(
            tool: .claude, directory: "/tmp/test", pid: 1234,
            launchArgs: ""
        )

        // Empty string should be stored as empty string (not nil)
        let fetched = try db.findActiveSession(pid: 1234, tool: .claude)
        #expect(fetched?.launchArgs == "")
    }

    // MARK: - Launch Directory Tests

    @Test("startSession defaults launchDirectory to directory")
    func startSessionSetsLaunchDirectoryToDirectoryByDefault() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(
            tool: .claude, directory: "/tmp/launch", pid: 1234
        )

        #expect(session.launchDirectory == "/tmp/launch")

        let fetched = try db.findActiveSession(pid: 1234, tool: .claude)
        #expect(fetched?.launchDirectory == "/tmp/launch")
    }

    @Test("startSession stores explicit launchDirectory")
    func startSessionExplicitLaunchDirectory() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(
            tool: .claude, directory: "/tmp/dir", pid: 1234,
            launchDirectory: "/tmp/launch"
        )

        #expect(session.launchDirectory == "/tmp/launch")
        #expect(session.directory == "/tmp/dir")

        let fetched = try db.findActiveSession(pid: 1234, tool: .claude)
        #expect(fetched?.launchDirectory == "/tmp/launch")
        #expect(fetched?.directory == "/tmp/dir")
    }

    @Test("updateSession does not change launchDirectory")
    func updateSessionDoesNotChangeLaunchDirectory() throws {
        let db = try SeshctlDatabase.temporary()
        _ = try db.startSession(
            tool: .claude, directory: "/tmp/launch", pid: 1234
        )

        _ = try db.updateSession(
            pid: 1234, tool: .claude, directory: "/tmp/worktree"
        )

        let fetched = try db.findActiveSession(pid: 1234, tool: .claude)
        #expect(fetched?.directory == "/tmp/worktree")
        #expect(fetched?.launchDirectory == "/tmp/launch")
    }

    // MARK: - Host Workspace Folder Tests

    @Test("startSession stores explicit hostWorkspaceFolder")
    func startSessionStoresHostWorkspaceFolder() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(
            tool: .claude, directory: "/tmp/dir", pid: 1234,
            hostWorkspaceFolder: "/tmp/workspace"
        )

        #expect(session.hostWorkspaceFolder == "/tmp/workspace")

        let fetched = try db.findActiveSession(pid: 1234, tool: .claude)
        #expect(fetched?.hostWorkspaceFolder == "/tmp/workspace")
    }

    @Test("startSession defaults hostWorkspaceFolder to nil")
    func startSessionDefaultsHostWorkspaceFolderToNil() throws {
        let db = try SeshctlDatabase.temporary()
        let session = try db.startSession(
            tool: .claude, directory: "/tmp/dir", pid: 1234
        )

        #expect(session.hostWorkspaceFolder == nil)

        let fetched = try db.findActiveSession(pid: 1234, tool: .claude)
        #expect(fetched?.hostWorkspaceFolder == nil)
    }

    // MARK: - Conversation-ID Matching Tests
    //
    // Required for tools (e.g. Cursor 1.7+) whose hook subprocess PIDs are
    // not stable across events. Matching is done on conversation_id+tool.

    @Test("findActiveSession(conversationId:tool:) returns the right session")
    func findActiveSessionByConversationId() throws {
        let db = try SeshctlDatabase.temporary()
        let created = try db.startSession(
            tool: .cursor, directory: "/tmp", pid: 1234,
            conversationId: "conv-abc"
        )

        let found = try db.findActiveSession(conversationId: "conv-abc", tool: .cursor)
        #expect(found?.id == created.id)
    }

    @Test("findActiveSession(conversationId:tool:) returns nil when no match")
    func findActiveSessionByConversationIdNoMatch() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(
            tool: .cursor, directory: "/tmp", pid: 1234,
            conversationId: "conv-abc"
        )

        let notFound = try db.findActiveSession(conversationId: "conv-xyz", tool: .cursor)
        #expect(notFound == nil)
    }

    @Test("findActiveSession(conversationId:tool:) requires tool match")
    func findActiveSessionByConversationIdRequiresTool() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(
            tool: .cursor, directory: "/tmp", pid: 1234,
            conversationId: "conv-abc"
        )

        // Same conversationId but wrong tool — no match
        let notFound = try db.findActiveSession(conversationId: "conv-abc", tool: .claude)
        #expect(notFound == nil)
    }

    @Test("findActiveSession(conversationId:tool:) skips completed sessions")
    func findActiveSessionByConversationIdSkipsCompleted() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(
            tool: .cursor, directory: "/tmp", pid: 1234,
            conversationId: "conv-abc"
        )
        try db.endSession(conversationId: "conv-abc", tool: .cursor)

        let notFound = try db.findActiveSession(conversationId: "conv-abc", tool: .cursor)
        #expect(notFound == nil)
    }

    @Test("updateSession(conversationId:tool:) updates matched row")
    func updateSessionByConversationId() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(
            tool: .cursor, directory: "/tmp", pid: 1234,
            conversationId: "conv-abc"
        )

        let updated = try db.updateSession(
            conversationId: "conv-abc", tool: .cursor,
            ask: "hello world",
            status: .working,
            transcriptPath: "/tmp/transcript.jsonl",
            directory: "/tmp/work"
        )

        #expect(updated.conversationId == "conv-abc")
        #expect(updated.lastAsk == "hello world")
        #expect(updated.status == .working)
        #expect(updated.transcriptPath == "/tmp/transcript.jsonl")
        #expect(updated.directory == "/tmp/work")
    }

    @Test("updateSession(conversationId:tool:) truncates ask to 500 chars")
    func updateSessionByConversationIdTruncates() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(
            tool: .cursor, directory: "/tmp", pid: 1234,
            conversationId: "conv-abc"
        )

        let longAsk = String(repeating: "x", count: 1000)
        let updated = try db.updateSession(
            conversationId: "conv-abc", tool: .cursor, ask: longAsk
        )

        #expect(updated.lastAsk?.count == 500)
    }

    @Test("updateSession(conversationId:tool:) lazy-creates with nil pid when no match")
    func updateSessionByConversationIdLazyCreate() throws {
        let db = try SeshctlDatabase.temporary()

        let created = try db.updateSession(
            conversationId: "conv-new", tool: .cursor,
            ask: "first prompt",
            status: .working
        )

        #expect(created.tool == .cursor)
        #expect(created.conversationId == "conv-new")
        #expect(created.pid == nil)
        #expect(created.lastAsk == "first prompt")
        #expect(created.status == .working)

        // The lazy-created row is findable via the conversation-id lookup.
        let found = try db.findActiveSession(conversationId: "conv-new", tool: .cursor)
        #expect(found?.id == created.id)
    }

    @Test("updateSession(conversationId:tool:) lazy-create writes host-app fields")
    func updateSessionByConversationIdLazyCreateWritesHostApp() throws {
        let db = try SeshctlDatabase.temporary()

        // Simulates the missed-sessionStart path: the first event seen for a
        // conversation is beforeSubmitPrompt; the hook passes --host-app-*
        // so the new row is focusable.
        let created = try db.updateSession(
            conversationId: "conv-late", tool: .cursor,
            ask: "first prompt",
            status: .working,
            directory: "/tmp/proj",
            hostAppBundleId: "com.todesktop.230313mzl4w4u92",
            hostAppName: "Cursor"
        )

        #expect(created.hostAppBundleId == "com.todesktop.230313mzl4w4u92")
        #expect(created.hostAppName == "Cursor")
        #expect(created.directory == "/tmp/proj")
    }

    @Test("updateSession(conversationId:tool:) fills nil host-app fields on later event")
    func updateSessionByConversationIdFillsNilHostApp() throws {
        let db = try SeshctlDatabase.temporary()

        // First event arrived without host-app info (e.g. an old hook script
        // that didn't pass them).
        let first = try db.updateSession(
            conversationId: "conv-late", tool: .cursor,
            ask: "first prompt"
        )
        #expect(first.hostAppBundleId == nil)
        #expect(first.hostAppName == nil)

        // Second event supplies them — should fill in the nils.
        let second = try db.updateSession(
            conversationId: "conv-late", tool: .cursor,
            reply: "answer",
            hostAppBundleId: "com.todesktop.230313mzl4w4u92",
            hostAppName: "Cursor"
        )
        #expect(second.id == first.id)
        #expect(second.hostAppBundleId == "com.todesktop.230313mzl4w4u92")
        #expect(second.hostAppName == "Cursor")
    }

    @Test("updateSession(conversationId:tool:) does not overwrite non-nil host-app fields")
    func updateSessionByConversationIdPreservesHostApp() throws {
        let db = try SeshctlDatabase.temporary()

        // Row was started with concrete host-app info (e.g., sessionStart fired).
        let started = try db.startSession(
            tool: .cursor, directory: "/tmp", pid: 4242,
            conversationId: "conv-abc",
            hostAppBundleId: "com.todesktop.230313mzl4w4u92",
            hostAppName: "Cursor"
        )
        #expect(started.hostAppBundleId == "com.todesktop.230313mzl4w4u92")

        // A later update tries to set DIFFERENT host-app values — the row
        // must keep the original (first-writer-wins).
        let updated = try db.updateSession(
            conversationId: "conv-abc", tool: .cursor,
            ask: "hi",
            hostAppBundleId: "com.something.else",
            hostAppName: "SomeOtherApp"
        )
        #expect(updated.hostAppBundleId == "com.todesktop.230313mzl4w4u92")
        #expect(updated.hostAppName == "Cursor")
    }

    @Test("updateSession(conversationId:tool:) waiting from idle is ignored")
    func updateSessionByConversationIdWaitingFromIdleIgnored() throws {
        let db = try SeshctlDatabase.temporary()
        try db.startSession(
            tool: .cursor, directory: "/tmp", pid: 1234,
            conversationId: "conv-abc"
        )

        // Late Notification: tries to set waiting when status is idle
        let session = try db.updateSession(
            conversationId: "conv-abc", tool: .cursor, status: .waiting
        )

        // Should remain idle — late Notification is stale
        #expect(session.status == .idle)
    }

    @Test("endSession(conversationId:tool:) sets status to completed by default")
    func endSessionByConversationId() throws {
        let db = try SeshctlDatabase.temporary()
        let created = try db.startSession(
            tool: .cursor, directory: "/tmp", pid: 1234,
            conversationId: "conv-abc"
        )

        try db.endSession(conversationId: "conv-abc", tool: .cursor)

        let fetched = try db.getSession(id: created.id)
        #expect(fetched?.status == .completed)
    }

    @Test("endSession(conversationId:tool:) accepts custom status")
    func endSessionByConversationIdCustomStatus() throws {
        let db = try SeshctlDatabase.temporary()
        let created = try db.startSession(
            tool: .cursor, directory: "/tmp", pid: 1234,
            conversationId: "conv-abc"
        )

        try db.endSession(conversationId: "conv-abc", tool: .cursor, status: .canceled)

        let fetched = try db.getSession(id: created.id)
        #expect(fetched?.status == .canceled)
    }

    @Test("endSession(conversationId:tool:) is a no-op when no match")
    func endSessionByConversationIdNoMatch() throws {
        let db = try SeshctlDatabase.temporary()

        // No matching active session — should not throw, should not insert.
        try db.endSession(conversationId: "conv-nonexistent", tool: .cursor)

        let sessions = try db.listSessions()
        #expect(sessions.isEmpty)
    }

    @Test("startSession(conversationId:tool:) creates a new row with nil pid")
    func startSessionByConversationId() throws {
        let db = try SeshctlDatabase.temporary()

        let session = try db.startSession(
            conversationId: "conv-abc",
            tool: .cursor,
            directory: "/tmp/cursor",
            hostAppBundleId: "com.todesktop.230313mzl4w4u92",
            hostAppName: "Cursor",
            transcriptPath: "/tmp/transcript.jsonl"
        )

        #expect(session.conversationId == "conv-abc")
        #expect(session.tool == .cursor)
        #expect(session.directory == "/tmp/cursor")
        #expect(session.pid == nil)
        #expect(session.hostAppBundleId == "com.todesktop.230313mzl4w4u92")
        #expect(session.hostAppName == "Cursor")
        #expect(session.transcriptPath == "/tmp/transcript.jsonl")
        #expect(session.status == .idle)
        // Persisted and findable by conversationId.
        let found = try db.findActiveSession(conversationId: "conv-abc", tool: .cursor)
        #expect(found?.id == session.id)
    }

    @Test("startSession(conversationId:tool:) ends existing active row for same conversationId+tool")
    func startSessionByConversationIdEndsExisting() throws {
        let db = try SeshctlDatabase.temporary()

        let first = try db.startSession(
            conversationId: "conv-abc",
            tool: .cursor,
            directory: "/tmp/cursor"
        )

        // A second start for the SAME conversationId+tool should end the
        // first and insert a new active row (mirrors the pid-keyed
        // end-then-insert pattern).
        let second = try db.startSession(
            conversationId: "conv-abc",
            tool: .cursor,
            directory: "/tmp/cursor"
        )

        let firstFetched = try db.getSession(id: first.id)
        #expect(firstFetched?.status == .completed)
        #expect(second.id != first.id)
        #expect(second.status == .idle)
        let found = try db.findActiveSession(conversationId: "conv-abc", tool: .cursor)
        #expect(found?.id == second.id)
    }

    @Test("startSession(conversationId:tool:) does not collapse distinct conversations regardless of PID collision")
    func startSessionByConversationIdRegression() throws {
        // Regression test for the Cursor PPID-coincidence bug: two
        // sessionStart hook invocations for DIFFERENT conversations whose
        // /bin/zsh -c subprocess happens to receive the same PPID must
        // produce two independent active rows, not one row that overwrites
        // the other. Conversation-id keying achieves that — and because the
        // conversationId-keyed startSession path stores pid: nil, there is
        // no pid to collide on at all.
        let db = try SeshctlDatabase.temporary()

        let first = try db.startSession(
            conversationId: "conv-A",
            tool: .cursor,
            directory: "/tmp/a"
        )

        let second = try db.startSession(
            conversationId: "conv-B",
            tool: .cursor,
            directory: "/tmp/b"
        )

        // Both rows are active and distinct.
        #expect(first.id != second.id)
        #expect(first.pid == nil)
        #expect(second.pid == nil)

        let firstFetched = try db.getSession(id: first.id)
        let secondFetched = try db.getSession(id: second.id)
        #expect(firstFetched?.status == .idle)
        #expect(secondFetched?.status == .idle)

        // Each is independently findable by its conversationId.
        let foundA = try db.findActiveSession(conversationId: "conv-A", tool: .cursor)
        let foundB = try db.findActiveSession(conversationId: "conv-B", tool: .cursor)
        #expect(foundA?.id == first.id)
        #expect(foundB?.id == second.id)
    }

    @Test("conversation-id and pid keying are isolated across tools")
    func conversationIdAndPidKeyingIsolated() throws {
        let db = try SeshctlDatabase.temporary()

        // Cursor row keyed by conversation_id (pid happens to be 1234)
        let cursorSession = try db.startSession(
            tool: .cursor, directory: "/tmp/cursor", pid: 1234,
            conversationId: "shared-id"
        )

        // Claude row keyed by pid with the SAME conversation_id string
        // (deliberately set to verify AND-filtering of conversation_id + tool)
        let claudeSession = try db.startSession(
            tool: .claude, directory: "/tmp/claude", pid: 5678,
            conversationId: "shared-id"
        )

        // Updating cursor by conversation_id hits cursor's row only.
        let updated = try db.updateSession(
            conversationId: "shared-id", tool: .cursor, ask: "for cursor"
        )
        #expect(updated.id == cursorSession.id)

        // Claude's row is unchanged.
        let claudeFetched = try db.getSession(id: claudeSession.id)
        #expect(claudeFetched?.lastAsk == nil)

        // Updating claude by conversation_id hits claude's row only.
        let claudeUpdated = try db.updateSession(
            conversationId: "shared-id", tool: .claude, ask: "for claude"
        )
        #expect(claudeUpdated.id == claudeSession.id)

        // Cursor's row's lastAsk is untouched by the claude update.
        let cursorFetched = try db.getSession(id: cursorSession.id)
        #expect(cursorFetched?.lastAsk == "for cursor")
    }
}
