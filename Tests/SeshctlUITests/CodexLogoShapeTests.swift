import Foundation
import SwiftUI
import Testing

@testable import SeshctlUI

@Suite("CodexLogoShape")
struct CodexLogoShapeTests {
    private let rect = CGRect(x: 0, y: 0, width: 24, height: 24)

    /// The arc-to-cubic conversion must keep the outline inside its 24×24
    /// viewBox and fill most of it. Tiny bounds mean the parser hit an
    /// unsupported command and bailed partway through.
    @Test("Parsed path fills its viewBox without spilling out")
    func boundsMatchViewBox() {
        let bounds = CodexLogoShape().path(in: rect).boundingRect

        #expect(bounds.width >= 22)
        #expect(bounds.height >= 22)
        let epsilon: CGFloat = 0.5
        #expect(bounds.minX >= -epsilon)
        #expect(bounds.minY >= -epsilon)
        #expect(bounds.maxX <= 24 + epsilon)
        #expect(bounds.maxY <= 24 + epsilon)
    }

    /// The `>_` prompt is drawn as separate subpaths inside the blossom.
    /// With an even-odd fill they're holes; if they were dropped, or the
    /// badge fell back to a non-zero fill, the mark would be a plain blob.
    @Test("The prompt is a hole under an even-odd fill")
    func promptIsCutOut() {
        let path = CodexLogoShape().path(in: rect)

        #expect(path.contains(CGPoint(x: 12, y: 4), eoFill: true), "solid blossom")
        #expect(!path.contains(CGPoint(x: 15, y: 15.4), eoFill: true), "the _ bar")
        #expect(!path.contains(CGPoint(x: 6.5, y: 9.5), eoFill: true), "the > chevron")
    }
}
