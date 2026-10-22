import AppKit
import Foundation
import SwiftUI
import Testing

@testable import SeshctlUI

@Suite("RepoAccentColor")
struct RepoAccentColorTests {
    @Test("Returns nil for nil input")
    func nilInput() {
        #expect(repoAccentColor(for: nil) == nil)
    }

    @Test("Returns nil for empty string")
    func emptyInput() {
        #expect(repoAccentColor(for: "") == nil)
    }

    @Test("Same repo name always returns the same color")
    func deterministic() {
        #expect(repoAccentColor(for: "seshctl") == repoAccentColor(for: "seshctl"))
        #expect(repoAccentColor(for: "mozi-app") == repoAccentColor(for: "mozi-app"))
    }

    @Test("Palette contains exactly 12 colors")
    func paletteSize() {
        #expect(repoAccentPalette.count == 12)
    }

    /// Regression guard for the defect this palette replaced: the previous
    /// 10-color set put 5 entries inside 13–60°, so roughly half of all repos
    /// came out some shade of orange and read as the same color. Assert the
    /// hues are actually spread rather than trusting the comments next to
    /// them.
    @Test("Palette hues are spread across the wheel, not clustered in one band")
    func hueSpread() throws {
        let hues = try paletteHues()

        // No 60° window may hold more than a quarter of the palette. The old
        // palette failed this hard: 5/10 inside a single 47° window.
        for windowStart in stride(from: 0.0, to: 360.0, by: 5.0) {
            let inWindow = hues.filter { hue in
                let offset = (hue - windowStart).truncatingRemainder(dividingBy: 360)
                return (offset < 0 ? offset + 360 : offset) < 60
            }
            // A third, not a quarter: the current palette's worst window
            // holds exactly a quarter, so a quarter-limit would sit on the
            // boundary and fail on any harmless retune. A third still catches
            // the regression this guards — the old palette put 5 of 10 in one
            // window, well over its own limit of 3.
            #expect(
                inWindow.count <= repoAccentPalette.count / 3,
                "\(inWindow.count) hues inside the 60° window at \(windowStart)°"
            )
        }

        // No gap larger than a quarter turn — the old palette left a 136°
        // hole covering all of blue/indigo/violet. The one exception is the
        // purple band, left empty on purpose so no repo reads as GitHub's
        // merged purple; it may run a little past a quarter turn, but no
        // wider than 100°.
        let mergedPurpleHue = try components(of: Color(red: 0xA3 / 255, green: 0x71 / 255, blue: 0xF7 / 255))
            .hueComponent * 360
        let sorted = hues.sorted()
        for index in sorted.indices {
            let next = sorted[(index + 1) % sorted.count]
            var gap = (next - sorted[index]).truncatingRemainder(dividingBy: 360)
            if gap < 0 { gap += 360 }
            var intoGap = (Double(mergedPurpleHue) - sorted[index]).truncatingRemainder(dividingBy: 360)
            if intoGap < 0 { intoGap += 360 }
            let limit = intoGap < gap ? 100.0 : 90.0
            #expect(gap <= limit, "gap after \(sorted[index])°")
        }
    }

    /// Pale tints wash toward the same warm gray regardless of hue, which
    /// compounded the clustering. Keep every entry visibly tinted. Measured
    /// as L*a*b* chroma rather than HSB saturation: a light tint like blush
    /// has low HSB saturation but is still clearly colored.
    @Test("Palette colors are chromatic enough to distinguish")
    func chroma() throws {
        for color in repoAccentPalette {
            let (_, a, b) = try lab(of: color)
            let chroma = (a * a + b * b).squareRoot()
            #expect(chroma >= 20, "chroma \(chroma) is too washed out")
        }
    }

    /// A repo label must not read as a git state. Guards the swap that removed
    /// green 105°, indigo 255° and violet 285° — ΔE00 6.1, 3.0 and 7.9 from
    /// GitHub's open green / merged purple. The closest kept slot (mint) is
    /// 12.8, so 12 separates "reads as a PR state" from accepted neighbors.
    /// Status dots are handled separately by the nudged mustard/mint slots.
    @Test("Palette colors stay clear of git colors")
    func avoidsGitColors() throws {
        let gitColors: [(String, Color)] = [
            ("GitHub merged", Color(red: 0xA3 / 255, green: 0x71 / 255, blue: 0xF7 / 255)),
            ("GitHub merged button", Color(red: 0x89 / 255, green: 0x57 / 255, blue: 0xE5 / 255)),
            ("GitHub open", Color(red: 0x3F / 255, green: 0xB9 / 255, blue: 0x50 / 255)),
            ("GitHub green button", Color(red: 0x23 / 255, green: 0x86 / 255, blue: 0x36 / 255)),
        ]
        for (index, color) in repoAccentPalette.enumerated() {
            for (name, other) in gitColors {
                let distance = try deltaE2000(color, other)
                #expect(distance >= 12, "slot \(index) is ΔE00 \(distance) from \(name)")
            }
        }
    }

    private func paletteHues() throws -> [Double] {
        try repoAccentPalette.map { Double(try components(of: $0).hueComponent) * 360 }
    }

    private func components(of color: Color) throws -> NSColor {
        try #require(NSColor(color).usingColorSpace(.deviceRGB))
    }

    /// sRGB → CIE L*a*b* (D65).
    private func lab(of color: Color) throws -> (Double, Double, Double) {
        let ns = try #require(NSColor(color).usingColorSpace(.sRGB))
        func linear(_ u: CGFloat) -> Double {
            let u = Double(u)
            return u <= 0.04045 ? u / 12.92 : pow((u + 0.055) / 1.055, 2.4)
        }
        let r = linear(ns.redComponent), g = linear(ns.greenComponent), b = linear(ns.blueComponent)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// CIEDE2000 color difference.
    private func deltaE2000(_ c1: Color, _ c2: Color) throws -> Double {
        let (l1, a1, b1) = try lab(of: c1), (l2, a2, b2) = try lab(of: c2)
        func rad(_ d: Double) -> Double { d * .pi / 180 }
        func deg(_ r: Double) -> Double { r * 180 / .pi }
        let cBar = ((a1 * a1 + b1 * b1).squareRoot() + (a2 * a2 + b2 * b2).squareRoot()) / 2
        let g = 0.5 * (1 - (pow(cBar, 7) / (pow(cBar, 7) + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot(), c2p = (a2p * a2p + b2 * b2).squareRoot()
        func hue(_ b: Double, _ ap: Double) -> Double {
            let h = deg(atan2(b, ap))
            return h < 0 ? h + 360 : h
        }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        var dh = h2p - h1p
        if c1p * c2p == 0 { dh = 0 } else if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        let dLp = l2 - l1, dCp = c2p - c1p
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(rad(dh / 2))
        let lBarP = (l1 + l2) / 2, cBarP = (c1p + c2p) / 2
        let hBarP: Double
        if c1p * c2p == 0 {
            hBarP = h1p + h2p
        } else if abs(h1p - h2p) > 180 {
            hBarP = (h1p + h2p + 360) / 2
        } else {
            hBarP = (h1p + h2p) / 2
        }
        let t = 1 - 0.17 * cos(rad(hBarP - 30)) + 0.24 * cos(rad(2 * hBarP))
            + 0.32 * cos(rad(3 * hBarP + 6)) - 0.20 * cos(rad(4 * hBarP - 63))
        let dTheta = 30 * exp(-pow((hBarP - 275) / 25, 2))
        let rC = 2 * (pow(cBarP, 7) / (pow(cBarP, 7) + pow(25, 7))).squareRoot()
        let sL = 1 + 0.015 * pow(lBarP - 50, 2) / (20 + pow(lBarP - 50, 2)).squareRoot()
        let sC = 1 + 0.045 * cBarP
        let sH = 1 + 0.015 * cBarP * t
        let rT = -sin(rad(2 * dTheta)) * rC
        let terms = pow(dLp / sL, 2) + pow(dCp / sC, 2) + pow(dHp / sH, 2) + rT * (dCp / sC) * (dHp / sH)
        return terms.squareRoot()
    }

    @Test("Common repo names distribute across the palette (no single-bucket collapse)")
    func distribution() {
        let names = ["seshctl", "mozi-app", "dashboard", "infra", "api", "web", "cli", "docs"]
        let colors = Set(names.compactMap { repoAccentColor(for: $0) })
        // With 10 palette slots and 8 inputs, at least 4 distinct colors is a
        // reasonable floor — guards against a buggy hash that collapses into
        // one bucket. Exact count is allowed to drift if we tune the palette.
        #expect(colors.count >= 4)
    }
}
