import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

/// Selection rules for the background titler. `nextTitlingCandidate` is pure
/// so these run without a database, a subprocess, or a real clock.
@Suite("SessionListViewModel — titling scheduler")
@MainActor
struct SessionTitlingSchedulerTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(
        id: String = "s1",
        tool: SessionTool = .claude,
        status: SessionStatus = .working,
        title: String? = nil
    ) -> Session {
        Session(
            id: id,
            conversationId: "conv-\(id)",
            tool: tool,
            directory: "/tmp/repo",
            status: status,
            pid: 1234,
            startedAt: now,
            updatedAt: now,
            title: title
        )
    }

    private func pick(
        _ sessions: [Session],
        lastAttemptAt: [String: Date] = [:],
        inFlight: Set<String> = []
    ) -> Session? {
        SessionListViewModel.nextTitlingCandidate(
            sessions: sessions,
            lastAttemptAt: lastAttemptAt,
            inFlight: inFlight,
            now: now
        )
    }

    @Test("Picks an untitled active Claude session")
    func picksUntitled() {
        #expect(pick([session()])?.id == "s1")
    }

    @Test("Never retitles a session that already has one")
    func skipsTitled() {
        // The freeze rule: automatic titling writes once and never revisits.
        #expect(pick([session(title: "Diversify repo color palette")]) == nil)
    }

    @Test("Skips tools that write no transcript")
    func skipsUntitleableTools() {
        #expect(pick([session(tool: .cursor)]) == nil)
        #expect(pick([session(tool: .gemini)]) == nil)
    }

    @Test("Titles Codex as well as Claude")
    func titlesCodex() {
        #expect(pick([session(tool: .codex)])?.id == "s1")
    }

    @Test("Skips sessions that are no longer active")
    func skipsInactive() {
        #expect(pick([session(status: .stale)]) == nil)
        #expect(pick([session(status: .completed)]) == nil)
        #expect(pick([session(status: .canceled)]) == nil)
    }

    @Test("Skips a session already being titled")
    func skipsInFlight() {
        #expect(pick([session()], inFlight: ["s1"]) == nil)
    }

    @Test("Backs off after a recent failed attempt")
    func backsOffAfterFailure() {
        // A failed attempt leaves title nil, so without the backoff this would
        // respawn a subprocess every 2s refresh forever.
        let recent = now.addingTimeInterval(-30)
        #expect(pick([session()], lastAttemptAt: ["s1": recent]) == nil)
    }

    @Test("Retries once the backoff window elapses")
    func retriesAfterBackoff() {
        let old = now.addingTimeInterval(-(SessionListViewModel.titleRetryBackoff + 1))
        #expect(pick([session()], lastAttemptAt: ["s1": old])?.id == "s1")
    }

    @Test("Takes the first eligible session in list order")
    func firstEligibleWins() {
        let candidates = [
            session(id: "titled", title: "Already named"),
            session(id: "cursor", tool: .cursor),
            session(id: "wanted"),
            session(id: "also-wanted"),
        ]
        #expect(pick(candidates)?.id == "wanted")
    }

    @Test("Returns nil when nothing qualifies")
    func nilWhenNothingQualifies() {
        #expect(pick([]) == nil)
        #expect(pick([session(tool: .gemini), session(id: "s2", title: "Named")]) == nil)
    }

    @Test("Claude, Codex and Pi are the titleable tools")
    func titleableToolSet() {
        // The tools that write a parseable transcript. Pi has no hooks, but its
        // transcripts parse, so a CLI-registered Pi session can be titled.
        #expect(SessionListViewModel.titleableTools == [.claude, .codex, .pi])
        // Guards the README compatibility claim: no transcript, no title.
        for tool in SessionTool.allCases where !SessionListViewModel.titleableTools.contains(tool) {
            #expect(pick([session(tool: tool)]) == nil)
        }
    }
}
