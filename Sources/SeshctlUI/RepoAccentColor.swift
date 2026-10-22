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

/// Curated 12-color dark-mode palette: hues spread around the wheel, starting
/// at 15°, with two slots nudged off the status dots and the purple and pure
/// green bands left empty (see "Git colors" below).
///
/// **Why even spacing matters more than semantic avoidance.** The previous
/// palette picked hues that dodged the other colors on a row — status dots
/// (orange/blue/green/red), assistant purple, unread orange. Dodging that
/// much of the wheel pushed 5 of its 10 entries into the 13–60° band and
/// left a 136° hole across blue/indigo/violet, so a coin-flip share of
/// repos came out some shade of orange and read as indistinguishable.
/// Colliding with a status hue is the lesser evil: the status dot is a
/// small circle in its own column and the repo accent is a 2pt bar plus
/// the repo-name text, so they're never confused for one another.
///
/// **Except for the two loudest status hues.** The working dot is system
/// green (~135°) and the waiting dot is vivid amber #FFA500 (~39°), and the
/// compact row tints the folder label with the repo accent, so an exact hue
/// match reads as a second status signal. Those two slots are moved and
/// softened instead: amber 45° → a muted mustard at 50°, emerald 135° → a
/// softer mint at 144°. Keep them clear of `StatusKind`'s green and
/// `StatusKind.waitingAmber` if either is retuned.
///
/// **Value alternates between ~0.78 and ~0.93 slot to slot** so that
/// same-family neighbors (lime → green → emerald) separate on brightness
/// as well as hue. Hashing can't guarantee that any given set of repos
/// lands far apart on the wheel — an even palette only removes the bias
/// that made clustering likely — so the second axis is what keeps
/// adjacent-slot collisions legible.
///
/// Saturation ~0.45–0.62 (up from 0.21–0.63, most of which sat below
/// 0.42). The old tints were pale enough that even well-separated hues
/// washed toward the same warm gray.
///
/// **Git colors.** The original green 105°, indigo 255° and violet 285° were
/// within CIEDE2000 3–8 of GitHub's open/added green (#3FB950) and merged
/// purple (#A371F7), so a repo label read as a PR state. They were replaced
/// by bronze, blush and deep teal, picked by searching sRGB for the three
/// colors farthest from those git colors, the status dots, the nine kept
/// slots and each other (all ≥ ΔE00 19). That leaves the purple band empty —
/// don't refill it. Bronze and deep teal sit darker (L* ~51) than the rest,
/// and blush is a light tint whose HSB saturation is low even though it's
/// clearly colored, so the tests gate on L*a*b* chroma, not HSB saturation.
///
/// The panel forces `.darkAqua` (see `FloatingPanel`), so these are tuned
/// for a dark background only and need no light-mode variant.
///
/// Changing the count reshuffles every repo's color, since assignment is
/// `hash % count`. That's a one-time reassignment, not a stability bug —
/// a given name still maps to the same slot on every launch.
let repoAccentPalette: [Color] = [
    Color(red: 0.93, green: 0.50, blue: 0.35),  // coral      15°
    Color(red: 0.82, green: 0.75, blue: 0.41),  // mustard    50° (off the waiting amber)
    Color(red: 0.75, green: 0.90, blue: 0.38),  // lime       75°
    Color(red: 0.60, green: 0.45, blue: 0.00),  // bronze     45° (replaced git-like green)
    Color(red: 0.47, green: 0.85, blue: 0.62),  // mint      144° (off the working green)
    Color(red: 0.33, green: 0.78, blue: 0.68),  // teal      165°
    Color(red: 0.36, green: 0.75, blue: 0.90),  // cyan      195°
    Color(red: 0.33, green: 0.49, blue: 0.82),  // azure     225°
    Color(red: 1.00, green: 0.80, blue: 0.90),  // blush     330° (replaced merged-like indigo)
    Color(red: 0.00, green: 0.55, blue: 0.55),  // deep teal 180° (replaced merged-like violet)
    Color(red: 0.92, green: 0.40, blue: 0.78),  // magenta   315°
    Color(red: 0.84, green: 0.35, blue: 0.49),  // rose      345°
]
