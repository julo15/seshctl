import AppKit
import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

private func makeSession(
    directory: String = "/tmp",
    gitRepoName: String? = nil,
    gitBranch: String? = nil,
    lastAsk: String? = nil,
    lastReply: String? = nil,
    status: SessionStatus = .idle,
    tool: SessionTool = .claude
) -> Session {
    Session(
        id: UUID().uuidString,
        conversationId: nil,
        tool: tool,
        directory: directory,
        launchDirectory: nil,
        hostWorkspaceFolder: nil,
        lastAsk: lastAsk,
        lastReply: lastReply,
        status: status,
        pid: nil,
        hostAppBundleId: nil,
        hostAppName: nil,
        windowId: nil,
        transcriptPath: nil,
        gitRepoName: gitRepoName,
        gitBranch: gitBranch,
        launchArgs: nil,
        startedAt: Date(),
        updatedAt: Date(),
        lastReadAt: nil
    )
}

// MARK: - senderDisplay

@Suite("Session.senderDisplay")
struct SessionSenderDisplayTests {

    @Test("Repo and dir basename match → repo name")
    func repoAndDirMatch() {
        let s = makeSession(
            directory: "/Users/julianlo/Documents/me/seshctl",
            gitRepoName: "seshctl"
        )
        #expect(s.senderDisplay == "seshctl")
    }

    @Test("Worktree (dir basename differs) → repo name; line 2 branch disambiguates")
    func worktreeDifferentDir() {
        let s = makeSession(
            directory: "/Users/julianlo/Documents/me/seshctl-wt2",
            gitRepoName: "seshctl"
        )
        #expect(s.senderDisplay == "seshctl")
    }

    @Test("No git context (gitRepoName nil) → dir basename")
    func noGitContext() {
        let s = makeSession(directory: "/Users/julianlo/scratch/foo", gitRepoName: nil)
        #expect(s.senderDisplay == "foo")
    }

    // MARK: - Worktree disambiguation contract
    //
    // After commit b85e9a7 the line-1 dirSuffix was dropped — worktrees of
    // the same repo collapse to identical sender values, and the line-2
    // branch slot is the disambiguator. These tests pin both the
    // distinct-branch case (line 2 disambiguates) and the same-branch case
    // (rare: detached HEADs, both forced to `main`) — the latter is an
    // accepted visual collision because there's no third line to fall
    // back to.

    @Test("Two worktrees, distinct branches → identical line 1; line 2 (gitBranch) disambiguates")
    func worktreeDistinctBranchesDisambiguate() {
        let main = makeSession(
            directory: "/work/seshctl",
            gitRepoName: "seshctl",
            gitBranch: "main"
        )
        let feature = makeSession(
            directory: "/work/seshctl-wt-feature",
            gitRepoName: "seshctl",
            gitBranch: "julo/feature"
        )
        // Line 1 is identical — sender helper returns just the repo name.
        #expect(main.senderDisplay == feature.senderDisplay)
        #expect(main.senderDisplay == "seshctl")
        // Line 2 (gitBranch) provides the visual difference between rows.
        #expect(main.gitBranch != feature.gitBranch)
    }

    @Test("Two worktrees, same branch → identical line 1 AND line 2 (accepted collision)")
    func worktreeSameBranchCollides() {
        // Rare case: two worktrees both pointed at `main` (or both detached
        // at HEAD). The branch slot can't disambiguate. Pinned here so the
        // collapse is intentional, not accidental — a future change that
        // re-introduces a dirSuffix or row-edge disambiguator should
        // touch this test.
        let a = makeSession(
            directory: "/work/a/tmp",
            gitRepoName: "seshctl",
            gitBranch: "main"
        )
        let b = makeSession(
            directory: "/work/b/tmp",
            gitRepoName: "seshctl",
            gitBranch: "main"
        )
        #expect(a.senderDisplay == b.senderDisplay)
        #expect(a.gitBranch == b.gitBranch)
    }
}

// MARK: - previewContent priority chain

@Suite("Session.previewContent")
struct SessionPreviewContentTests {

    @Test("Reply present → .reply(text), regardless of lastAsk")
    func replyWinsOverAsk() {
        let s = makeSession(
            lastAsk: "ignored prompt",
            lastReply: "hello",
            status: .working
        )
        #expect(s.previewContent == .reply("hello"))
    }

    @Test("Ask present, no reply → .userPrompt(text)")
    func askWhenNoReply() {
        let s = makeSession(
            lastAsk: "refactor X",
            lastReply: nil,
            status: .idle
        )
        #expect(s.previewContent == .userPrompt("refactor X"))
    }

    @Test("Both nil → .statusHint for the session's status (.working → \"Working…\")")
    func bothNilFallsBackToStatusHint() {
        let s = makeSession(lastAsk: nil, lastReply: nil, status: .working)
        #expect(s.previewContent == .statusHint("Working\u{2026}"))
    }

    @Test("Empty-string lastReply with non-empty lastAsk → .userPrompt")
    func emptyReplyFallsThroughToAsk() {
        let s = makeSession(
            lastAsk: "refactor X",
            lastReply: "",
            status: .idle
        )
        #expect(s.previewContent == .userPrompt("refactor X"))
    }

    @Test("Both empty strings → .statusHint")
    func bothEmptyStringsFallThroughToStatusHint() {
        let s = makeSession(lastAsk: "", lastReply: "", status: .idle)
        #expect(s.previewContent == .statusHint("Idle"))
    }

    @Test("Whitespace-only lastReply falls through to lastAsk")
    func whitespaceReplyFallsThrough() {
        let s = makeSession(
            lastAsk: "refactor X",
            lastReply: "   ",
            status: .idle
        )
        #expect(s.previewContent == .userPrompt("refactor X"))
    }

    @Test("Whitespace-only lastAsk (with empty lastReply) falls through to statusHint")
    func whitespaceAskFallsThroughToStatusHint() {
        // Symmetric to whitespaceReplyFallsThrough: ensures the nonEmpty
        // helper is wired on the lastAsk side too. Without this, a regression
        // that drops the whitespace check on lastAsk would render the
        // whitespace verbatim instead of falling through.
        let s = makeSession(
            lastAsk: "   ",
            lastReply: nil,
            status: .idle
        )
        #expect(s.previewContent == .statusHint("Idle"))
    }

    @Test("Multiline reply — preserves body, trims edges only")
    func multilineReplyPreservesBodyTrimsEdges() {
        let s = makeSession(
            lastReply: "\n\n  first real line  \nsecond line",
            status: .idle
        )
        #expect(s.previewContent == .reply("first real line  \nsecond line"))
    }

    @Test("Reply with trailing whitespace+newlines — trims trailing edge")
    func replyWithTrailingWhitespaceTrimmed() {
        let s = makeSession(lastReply: "hello\n   \n   ", status: .idle)
        #expect(s.previewContent == .reply("hello"))
    }

    @Test("Reply with internal newlines — preserves them verbatim")
    func replyWithInternalNewlinesPreserved() {
        let s = makeSession(lastReply: "line 1\nline 2\nline 3", status: .idle)
        #expect(s.previewContent == .reply("line 1\nline 2\nline 3"))
    }
}

// MARK: - statusHint

@Suite("Session.statusHint(for:)")
struct SessionStatusHintTests {

    @Test(".working → \"Working…\"")
    func working() {
        #expect(Session.statusHint(for: .working) == "Working\u{2026}")
    }

    @Test(".waiting → \"Waiting…\"")
    func waiting() {
        #expect(Session.statusHint(for: .waiting) == "Waiting\u{2026}")
    }

    @Test(".idle → \"Idle\"")
    func idle() {
        #expect(Session.statusHint(for: .idle) == "Idle")
    }

    @Test(".completed → \"Done\"")
    func completed() {
        #expect(Session.statusHint(for: .completed) == "Done")
    }

    @Test(".canceled → \"Canceled\"")
    func canceled() {
        #expect(Session.statusHint(for: .canceled) == "Canceled")
    }

    @Test(".stale → \"Ended\"")
    func stale() {
        #expect(Session.statusHint(for: .stale) == "Ended")
    }
}

// MARK: - accessibilityLabel

@Suite("Session.accessibilityLabel(hostApp:agent:)")
struct SessionAccessibilityLabelTests {

    private func makeHostApp(name: String) -> HostAppInfo {
        HostAppInfo(bundleId: "test.bundle", name: name, icon: NSImage())
    }

    @Test("Local — Ghostty + claude → \"Ghostty, Claude\"")
    func localGhosttyClaude() {
        let host = makeHostApp(name: "Ghostty")
        #expect(Session.accessibilityLabel(hostApp: host, agent: .claude) == "Ghostty, Claude")
    }

    @Test("Remote — nil hostApp + claude → \"Globe, Claude\"")
    func remoteNilClaude() {
        #expect(Session.accessibilityLabel(hostApp: nil, agent: .claude) == "Globe, Claude")
    }

    @Test("Local — Terminal + codex → \"Terminal, Codex\"")
    func localTerminalCodex() {
        let host = makeHostApp(name: "Terminal")
        #expect(Session.accessibilityLabel(hostApp: host, agent: .codex) == "Terminal, Codex")
    }

    @Test("Local — Ghostty + gemini → \"Ghostty, Gemini\"")
    func localGhosttyGemini() {
        let host = makeHostApp(name: "Ghostty")
        #expect(Session.accessibilityLabel(hostApp: host, agent: .gemini) == "Ghostty, Gemini")
    }
}

// MARK: - previewContent(awaySummary:) priority chain

@Suite("Session.previewContent(awaySummary:)")
struct SessionPreviewContentAwaySummaryTests {

    @Test("Recap wins over lastReply (even when reply would otherwise be returned)")
    func recapWinsOverReply() {
        let s = makeSession(lastAsk: "ignored", lastReply: "ignored reply")
        #expect(
            s.previewContent(awaySummary: "Shipped PRs #31, #32")
                == .awaySummary("Shipped PRs #31, #32")
        )
    }

    @Test("Recap wins over lastAsk when no reply is present")
    func recapWinsOverAsk() {
        let s = makeSession(lastAsk: "ignored ask", lastReply: nil)
        #expect(
            s.previewContent(awaySummary: "Idle work recap")
                == .awaySummary("Idle work recap")
        )
    }

    @Test("Recap wins over statusHint when neither reply nor ask is present")
    func recapWinsOverStatusHint() {
        let s = makeSession(lastAsk: nil, lastReply: nil, status: .working)
        #expect(
            s.previewContent(awaySummary: "Some recap")
                == .awaySummary("Some recap")
        )
    }

    @Test("nil summary falls through to existing chain (.reply)")
    func nilSummaryFallsThrough() {
        let s = makeSession(lastReply: "hello")
        #expect(s.previewContent(awaySummary: nil) == .reply("hello"))
        // Sanity-check: matches the no-arg `previewContent` exactly.
        #expect(s.previewContent(awaySummary: nil) == s.previewContent)
    }

    @Test("Empty-string summary falls through to existing chain")
    func emptySummaryFallsThrough() {
        let s = makeSession(lastReply: "hello")
        #expect(s.previewContent(awaySummary: "") == .reply("hello"))
    }

    @Test("Whitespace-only summary falls through to existing chain")
    func whitespaceSummaryFallsThrough() {
        let s = makeSession(lastReply: "hello")
        #expect(s.previewContent(awaySummary: "   \n   ") == .reply("hello"))
    }

    @Test("Multiline summary — preserves body, trims edges only")
    func multilineSummaryPreservesBodyTrimsEdges() {
        let s = makeSession(lastReply: "ignored")
        #expect(
            s.previewContent(awaySummary: "\n\n  first real line  \nsecond")
                == .awaySummary("first real line  \nsecond")
        )
    }

    @Test("Summary with trailing whitespace+newlines — trims trailing edge")
    func summaryWithTrailingWhitespaceTrimmed() {
        let s = makeSession(lastReply: nil, status: .idle)
        #expect(
            s.previewContent(awaySummary: "hello\n   \n   ")
                == .awaySummary("hello")
        )
    }

    @Test("Summary with internal newlines — preserves them verbatim")
    func summaryWithInternalNewlinesPreserved() {
        let s = makeSession(lastReply: nil, status: .idle)
        #expect(
            s.previewContent(awaySummary: "line 1\nline 2\nline 3")
                == .awaySummary("line 1\nline 2\nline 3")
        )
    }
}
