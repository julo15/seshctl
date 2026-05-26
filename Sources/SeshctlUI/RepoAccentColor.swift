import SwiftUI
import SeshctlCore

/// Returns a stable accent color for a repository, derived by hashing the
/// repo name into a curated palette. Used to tint the per-row accent bar,
/// the row's repo-name (sender) field, and the tree-view group-header
/// dot, so sessions from the same repo visually cluster across local and
/// remote rows. Worktree/dir labels and branch names stay monotone so
/// only one token on the row carries the accent.
///
/// Returns `nil` for `nil`/empty input so callers can fall back to their
/// default foreground style — rows without a repo identity (e.g., non-git
/// directories) stay unstyled rather than picking an arbitrary color.
public func repoAccentColor(for name: String?) -> Color? {
    guard let name, !name.isEmpty else { return nil }
    let index = Int(StableHash.djb2(name) % UInt64(repoAccentPalette.count))
    return repoAccentPalette[index]
}

/// Curated 10-color dark-mode palette. Hues chosen to stay clear of
/// existing color semantics on a session row:
///   - status dots (orange/blue/green/red)   — AnimatedStatusDot, StatusKind
///   - assistant role (#937CBF purple)       — RoleColors.assistantPurple
///   - unread pill (orange)                  — UnreadPill
///
/// Saturation ~0.45–0.60 and brightness ~0.78–0.88 keep the tints
/// readable on a dark background without overpowering the
/// semibold-monospaced repo name.
let repoAccentPalette: [Color] = [
    Color(red: 0.93, green: 0.66, blue: 0.49),  // soft peach
    Color(red: 0.85, green: 0.64, blue: 0.67),  // dusty rose
    Color(red: 0.83, green: 0.73, blue: 0.53),  // warm amber
    Color(red: 0.64, green: 0.78, blue: 0.62),  // sage
    Color(red: 0.51, green: 0.74, blue: 0.74),  // slate teal
    Color(red: 0.95, green: 0.74, blue: 0.35),  // saffron gold
    Color(red: 0.81, green: 0.62, blue: 0.76),  // mauve
    Color(red: 0.86, green: 0.58, blue: 0.50),  // terracotta
    Color(red: 0.80, green: 0.80, blue: 0.50),  // muted gold
    Color(red: 0.62, green: 0.83, blue: 0.74),  // cool mint
]
