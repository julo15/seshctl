import SwiftUI
import SeshctlCore

/// Returns a stable accent color for a repository. Used to tint the per-row
/// accent bar, the row's repo-name (sender) field, and the tree-view
/// group-header dot, so sessions from the same repo visually cluster across
/// local and remote rows. Worktree/dir labels and branch names stay monotone
/// so only one token on the row carries the accent.
///
/// The slot comes from `RepoColorAssigner`, not a bare `hash % count`: the
/// hash is only the repo's preferred slot, and a repo whose slot is already
/// held by another recently seen repo gets the free slot that looks most
/// different. The choice is saved, so a repo keeps its color across launches.
///
/// Pass `claimsSlot: false` from surfaces that list repos the user isn't
/// working in (History search results): they get a repo's saved color if it
/// has one and its hash color otherwise, without taking a slot. Otherwise a
/// few searches would fill the palette and live repos would share colors.
///
/// Returns `nil` for `nil`/empty input so callers can fall back to their
/// default foreground style — rows without a repo identity (e.g., non-git
/// directories) stay unstyled rather than picking an arbitrary color.
public func repoAccentColor(for name: String?, claimsSlot: Bool = true) -> Color? {
    repoAccentColor(for: name, claimsSlot: claimsSlot, assigner: repoColorAssigner)
}

func repoAccentColor(for name: String?, claimsSlot: Bool, assigner: RepoColorAssigner) -> Color? {
    guard let name, !name.isEmpty else { return nil }
    let slot = claimsSlot ? assigner.slot(for: name) : assigner.peekSlot(for: name)
    return repoAccentPalette[slot]
}

let repoColorAssigner = makeRepoColorAssigner()

func makeRepoColorAssigner(defaults: UserDefaults = .standard) -> RepoColorAssigner {
    RepoColorAssigner(slotCount: repoAccentPaletteRGB.count, distance: repoAccentSlotDistance, defaults: defaults)
}

/// CIE76 ΔE between two palette slots. Coarser than CIEDE2000, but only used
/// to rank fallback slots, where it's plenty.
func repoAccentSlotDistance(_ a: Int, _ b: Int) -> Double {
    let la = repoAccentPaletteLab[a], lb = repoAccentPaletteLab[b]
    let dl = la.0 - lb.0, da = la.1 - lb.1, db = la.2 - lb.2
    return (dl * dl + da * da + db * db).squareRoot()
}

private let repoAccentPaletteLab = repoAccentPaletteRGB.map(srgbToLab)

/// sRGB → CIE L*a*b* (D65).
func srgbToLab(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
    func linear(_ u: Double) -> Double { u <= 0.04045 ? u / 12.92 : pow((u + 0.055) / 1.055, 2.4) }
    let r = linear(rgb.0), g = linear(rgb.1), b = linear(rgb.2)
    let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0 }
    return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
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
/// Changing the count shifts every repo's preferred slot, but saved
/// assignments still in range keep their color; only out-of-range ones are
/// reassigned.
private let repoAccentPaletteRGB: [(Double, Double, Double)] = [
    (0.93, 0.50, 0.35),  // coral      15°
    (0.82, 0.75, 0.41),  // mustard    50° (off the waiting amber)
    (0.75, 0.90, 0.38),  // lime       75°
    (0.60, 0.45, 0.00),  // bronze     45° (replaced git-like green)
    (0.47, 0.85, 0.62),  // mint      144° (off the working green)
    (0.33, 0.78, 0.68),  // teal      165°
    (0.30, 0.63, 0.78),  // cyan      198° (dimmed; 0.90 read too bright)
    (0.33, 0.49, 0.82),  // azure     225°
    (1.00, 0.80, 0.90),  // blush     330° (replaced merged-like indigo)
    (0.00, 0.55, 0.55),  // deep teal 180° (replaced merged-like violet)
    (0.92, 0.40, 0.78),  // magenta   315°
    (0.84, 0.35, 0.49),  // rose      345°
]

let repoAccentPalette: [Color] = repoAccentPaletteRGB.map { Color(red: $0.0, green: $0.1, blue: $0.2) }
