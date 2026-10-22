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
        // hole covering all of blue/indigo/violet.
        let sorted = hues.sorted()
        for index in sorted.indices {
            let next = sorted[(index + 1) % sorted.count]
            let gap = (next - sorted[index]).truncatingRemainder(dividingBy: 360)
            #expect((gap < 0 ? gap + 360 : gap) <= 90, "gap after \(sorted[index])°")
        }
    }

    /// Pale tints wash toward the same warm gray regardless of hue, which
    /// compounded the clustering. Keep every entry meaningfully saturated.
    @Test("Palette colors are saturated enough to distinguish")
    func saturation() throws {
        for color in repoAccentPalette {
            let saturation = try components(of: color).saturationComponent
            #expect(saturation >= 0.40, "saturation \(saturation) is too washed out")
        }
    }

    private func paletteHues() throws -> [Double] {
        try repoAccentPalette.map { Double(try components(of: $0).hueComponent) * 360 }
    }

    private func components(of color: Color) throws -> NSColor {
        try #require(NSColor(color).usingColorSpace(.deviceRGB))
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
