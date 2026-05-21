import Foundation
import SeshctlCore

// MARK: - Remote (claude.ai) display helpers
//
// Mirrors the local-side helpers in `Session+Display.swift`. The view layer
// composes these into the same `SenderDisplay` / `PreviewContent` shapes so
// remote and local rows can share the same row template (Phase 1 of the
// Gmail-style row layout).

extension RemoteClaudeCodeSession {
    /// Repo name for the row's line-1 sender slot. Sourced from `repoUrl` via
    /// `DisplayRow.repoShortName(from:)`. Falls back to the literal
    /// `"Remote"` when no repo URL is attached.
    var senderDisplay: String {
        DisplayRow.repoShortName(from: repoUrl) ?? "Remote"
    }

    /// Preview content for the row's line-1 preview slot. Remote sessions
    /// have no `lastReply` / `lastAsk` priority chain — the title is the only
    /// content surface — so this always returns `.reply(title)`.
    var previewContent: PreviewContent {
        .reply(title)
    }

    /// Priority-chain preview content with an optional claude.ai assistant-text
    /// recap injected at the top of the chain. When a non-empty summary is
    /// supplied, returns `.awaySummary` — same case the local-side recap
    /// uses, so remote rows pick up the clock-glyph rendering the row view
    /// already has wired up for `PreviewContent.awaySummary`. Nil / empty /
    /// whitespace summaries fall through to the existing `.reply(title)`
    /// chain.
    ///
    /// Mirrors `Session.previewContent(awaySummary:)`.
    func previewContent(awaySummary: String?) -> PreviewContent {
        if let summary = awaySummary.nonEmpty, let body = Session.trimmedPreviewBody(of: summary) {
            return .awaySummary(body)
        }
        return previewContent
    }

    /// First branch in the `branches` array, or `nil` when the array is
    /// empty. The view layer uses `nil` as the signal to collapse line 2 on
    /// remote rows.
    var branchDisplay: String? {
        branches.first
    }
}
