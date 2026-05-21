import SwiftUI

/// Layout constants for the line-1 sender column. Centralized so a future
/// tuning pass touches one place; the row views consume the named
/// accessors rather than spelling out literals.
enum SenderColumnLayout {
    /// Legacy fixed sender-column width (pt). Retained for callers that
    /// still want a column-style frame; the stacked row layout introduced
    /// after the Gmail two-column pass no longer constrains the sender to
    /// this width. See `.agents/plans/2026-04-29-1730-row-ui-gmail-redesign.md`.
    static let width: CGFloat = 180

    /// Sender (line 1) font size. The sender now reads as the row's primary
    /// heading in the stacked layout — bumped above the preview body size
    /// so the repo/folder name stands out against the chat text below. The
    /// monospace face doesn't widen on bold, so we bump 1pt on unread to
    /// mimic the Gmail "unread reads bigger" effect.
    static func senderSize(isUnread: Bool) -> CGFloat {
        isUnread ? 16 : 15
    }

    /// Subtitle (line 2) font size — branch label or directory-path
    /// fallback. Demoted below the sender and below the preview so line 2
    /// reads as quiet context rather than a competing heading.
    static func subtitleSize(isUnread: Bool) -> CGFloat {
        isUnread ? 12 : 11
    }
}

/// Renders the line-1 sender — the repo name (or directory basename when the
/// session has no git context). Worktree disambiguation lives on line 2's
/// branch slot, so this view is intentionally thin: a single monospaced
/// `Text` with stock tail truncation. The earlier two-part `repo · suffix`
/// machinery was removed when production callers stopped populating a dir
/// suffix; if a future case needs it, prefer extending `senderDisplay` to
/// return a richer type rather than reintroducing the buffered char-budget
/// truncation.
struct SenderText: View {
    /// Pre-resolved repo name (or directory basename) sourced from
    /// `Session.senderDisplay` / `RemoteClaudeCodeSession.senderDisplay`.
    let display: String
    /// When true, render at the bumped unread size (see
    /// `SenderColumnLayout.senderSize(isUnread:)`). Bold weight is applied by
    /// the parent VStack — this only adjusts size.
    var isUnread: Bool = false

    var body: some View {
        Text(display)
            .font(.system(size: SenderColumnLayout.senderSize(isUnread: isUnread), design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
