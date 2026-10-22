import SwiftUI

/// SwiftUI `Shape` rendering the Codex mark: OpenAI's rounded blossom with
/// a `>_` prompt cut out of it. Fill it with `FillStyle(eoFill: true)` —
/// the prompt is a hole, so a non-zero fill paints it solid.
///
/// The geometry is the Codex icon from LobeHub's icon set
/// (`@lobehub/icons-static-svg` 1.98.0, `icons/codex.svg`, 24×24 viewBox).
/// That source draws its rounded corners with arc commands, which
/// `SVGPathParser` doesn't handle, so the path below is the same outline
/// with each arc converted to cubic Béziers (absolute `M L C Z` only).
/// To update it, run the new upstream `d` through an arc-to-cubic
/// converter (e.g. Python `svgelements`' `approximate_arcs_with_cubics()`)
/// rather than pasting it in directly.
struct CodexLogoShape: Shape {
    /// SVG `viewBox` of the source artwork.
    private static let viewBox = CGRect(x: 0, y: 0, width: 24, height: 24)

    private static let pathData: String = """
    M8.086 0.457 C9.049 0.061 10.098 -0.082 11.132 0.042 C12.465 0.195 13.653 0.762 14.696 1.742 C14.71 1.755 14.727 1.765 14.746 1.77 C14.765 1.775 14.784 1.775 14.803 1.771 C16.211 1.425 17.565 1.547 18.864 2.137 L18.927 2.167 L19.081 2.243 C20.438 2.946 21.411 4.013 21.999 5.441 C22.277 6.12 22.417 6.829 22.42 7.567 C22.44 8.117 22.379 8.666 22.24 9.198 C22.233 9.225 22.233 9.254 22.24 9.281 C22.247 9.308 22.261 9.333 22.28 9.353 C23.066 10.15 23.613 11.152 23.858 12.244 C24.243 14.145 23.848 15.859 22.675 17.384 L22.493 17.604 C21.716 18.493 20.696 19.137 19.559 19.455 C19.534 19.462 19.511 19.475 19.493 19.493 C19.474 19.511 19.46 19.533 19.451 19.557 C19.196 20.293 18.94 20.921 18.464 21.549 C17.265 23.131 15.502 24.011 13.516 24 C11.933 23.992 10.53 23.413 9.306 22.264 C9.287 22.247 9.265 22.235 9.24 22.229 C9.216 22.224 9.19 22.225 9.166 22.232 C8.648 22.399 8.126 22.423 7.562 22.417 C6.661 22.41 5.773 22.197 4.967 21.795 C4.123 21.376 3.388 20.766 2.821 20.014 C2.618 19.745 2.417 19.492 2.27 19.193 C2.067 18.781 1.902 18.352 1.775 17.91 C1.509 16.907 1.503 15.852 1.758 14.846 C1.766 14.822 1.769 14.797 1.766 14.772 C1.764 14.76 1.759 14.748 1.753 14.737 C1.746 14.726 1.738 14.716 1.729 14.708 C1.113 14.085 0.641 13.333 0.349 12.506 C0.155 11.997 0.043 11.461 0.016 10.917 C-0.032 10.201 0.031 9.482 0.204 8.785 C0.654 7.301 1.513 6.137 2.781 5.292 C3.063 5.104 3.331 4.958 3.583 4.854 C3.869 4.734 4.156 4.634 4.444 4.55 C4.465 4.544 4.483 4.533 4.499 4.518 C4.514 4.502 4.525 4.484 4.531 4.463 C4.749 3.678 5.125 2.945 5.635 2.31 C6.315 1.464 7.132 0.846 8.086 0.457 Z M7.282 8.307 C7.193 8.151 7.057 8.028 6.894 7.955 C6.731 7.881 6.548 7.861 6.373 7.897 C6.197 7.934 6.038 8.025 5.918 8.158 C5.797 8.29 5.722 8.458 5.702 8.636 C5.683 8.814 5.72 8.993 5.809 9.149 L7.503 12.114 L5.815 14.962 C5.733 15.116 5.699 15.291 5.72 15.464 C5.741 15.637 5.815 15.8 5.931 15.93 C6.047 16.06 6.201 16.151 6.371 16.19 C6.541 16.23 6.719 16.216 6.88 16.151 C7.042 16.086 7.18 15.972 7.275 15.826 L9.215 12.554 C9.292 12.425 9.332 12.278 9.334 12.128 C9.335 11.978 9.296 11.83 9.222 11.7 L7.282 8.307 Z M12.728 14.547 C12.556 14.557 12.391 14.62 12.255 14.726 C12.119 14.832 12.019 14.977 11.968 15.142 C11.917 15.306 11.917 15.483 11.968 15.647 C12.019 15.812 12.119 15.957 12.255 16.063 C12.391 16.169 12.556 16.232 12.728 16.242 L17.576 16.242 C17.749 16.234 17.916 16.172 18.054 16.066 C18.191 15.96 18.293 15.814 18.345 15.649 C18.397 15.483 18.397 15.305 18.345 15.139 C18.293 14.974 18.191 14.828 18.054 14.722 C17.916 14.616 17.749 14.554 17.576 14.546 L12.728 14.546 Z
    """

    /// Parsed once, in normalized 0..1 coordinates. See
    /// `ClaudeLogoShape.normalizedPath`.
    private static let normalizedPath: Path = {
        let normalize = { (p: CGPoint) -> CGPoint in
            CGPoint(x: p.x / viewBox.width, y: p.y / viewBox.height)
        }
        return SVGPathParser.parse(pathData, transform: normalize)
    }()

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height)
        let dx = rect.minX + (rect.width - scale) / 2
        let dy = rect.minY + (rect.height - scale) / 2
        return Self.normalizedPath.applying(
            CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
        )
    }
}
