import SwiftUI

/// SwiftUI `Shape` rendering the Claude AI mark.
///
/// The mark's geometry is the `d` attribute from the official symbol SVG
/// (Wikimedia Commons, public-domain trademark — `Claude_AI_symbol.svg`,
/// 100×100 viewBox). We parse the path string at draw time rather than
/// bundling the SVG as an asset because SwiftPM does not run `actool` on
/// macOS, so an `Image(_, bundle:)` of an `.xcassets` SVG renders as a
/// blank rectangle. Parsing into a `Path` gives a true vector shape that
/// scales without aliasing and tints via `.foregroundStyle`.
///
/// The parser is scoped to the commands present in this single path:
/// `M m L l H h V v C c Z z`. It is not a general-purpose SVG path parser.
struct ClaudeLogoShape: Shape {
    /// SVG `viewBox` of the source artwork.
    private static let viewBox = CGRect(x: 0, y: 0, width: 100, height: 100)

    /// Raw `d` attribute from `Claude_AI_symbol.svg`. Kept as a single
    /// string so updates from the upstream SVG are a one-line swap.
    private static let pathData: String = """
    m19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z
    """

    /// Parsed once at first access in normalized 0..1 coordinates (i.e.
    /// the `viewBox` divided through by 100). SwiftUI calls `path(in:)`
    /// every layout pass and animation frame; reusing the parsed `Path`
    /// avoids re-tokenizing ~hundreds of tokens per call.
    private static let normalizedPath: Path = {
        let normalize = { (p: CGPoint) -> CGPoint in
            CGPoint(x: p.x / viewBox.width, y: p.y / viewBox.height)
        }
        return SVGPathParser.parse(pathData, transform: normalize)
    }()

    func path(in rect: CGRect) -> Path {
        // Aspect-fit the 1×1 normalized path into `rect` (center it if
        // the bounding rect isn't square — preserves the mark's
        // proportions).
        let scale = min(rect.width, rect.height)
        let dx = rect.minX + (rect.width - scale) / 2
        let dy = rect.minY + (rect.height - scale) / 2
        return Self.normalizedPath.applying(
            CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
        )
    }
}

/// Minimal SVG path-data parser shared by `ClaudeLogoShape` and
/// `CodexLogoShape`. Handles only the commands appearing in their path
/// data — adding new commands requires extending the `switch` below. Tokenization tolerates the compact SVG style where
/// numbers run together with no whitespace (e.g. `19.7-11`, `.3-1`).
enum SVGPathParser {
    static func parse(_ d: String, transform: (CGPoint) -> CGPoint) -> Path {
        var path = Path()
        let tokens = tokenize(d)

        var cursor = CGPoint.zero
        var subpathStart = CGPoint.zero
        var i = 0
        var lastCmd: Character = " "

        // Reads the next numeric token, advancing `i`. Crashes on
        // malformed input — acceptable here because the input is a fixed
        // string baked into the binary; bad input would be a build-time
        // bug, not a runtime condition.
        func num() -> CGFloat {
            defer { i += 1 }
            return CGFloat(Double(tokens[i])!)
        }

        while i < tokens.count {
            let token = tokens[i]
            let cmd: Character
            if let ch = token.first, ch.isLetter {
                cmd = ch
                i += 1
            } else {
                // Implicit repeat. After M/m the implicit follow-up is
                // L/l per SVG spec; everything else repeats verbatim.
                switch lastCmd {
                case "M": cmd = "L"
                case "m": cmd = "l"
                default:  cmd = lastCmd
                }
            }
            lastCmd = cmd

            switch cmd {
            case "M":
                cursor = CGPoint(x: num(), y: num())
                subpathStart = cursor
                path.move(to: transform(cursor))
            case "m":
                cursor.x += num(); cursor.y += num()
                subpathStart = cursor
                path.move(to: transform(cursor))
            case "L":
                cursor = CGPoint(x: num(), y: num())
                path.addLine(to: transform(cursor))
            case "l":
                cursor.x += num(); cursor.y += num()
                path.addLine(to: transform(cursor))
            case "H":
                cursor.x = num()
                path.addLine(to: transform(cursor))
            case "h":
                cursor.x += num()
                path.addLine(to: transform(cursor))
            case "V":
                cursor.y = num()
                path.addLine(to: transform(cursor))
            case "v":
                cursor.y += num()
                path.addLine(to: transform(cursor))
            case "C":
                let c1 = CGPoint(x: num(), y: num())
                let c2 = CGPoint(x: num(), y: num())
                cursor  = CGPoint(x: num(), y: num())
                path.addCurve(to: transform(cursor),
                              control1: transform(c1),
                              control2: transform(c2))
            case "c":
                let c1 = CGPoint(x: cursor.x + num(), y: cursor.y + num())
                let c2 = CGPoint(x: cursor.x + num(), y: cursor.y + num())
                let end = CGPoint(x: cursor.x + num(), y: cursor.y + num())
                cursor = end
                path.addCurve(to: transform(end),
                              control1: transform(c1),
                              control2: transform(c2))
            case "Z", "z":
                cursor = subpathStart
                path.closeSubpath()
            default:
                // Unsupported command — bail rather than silently produce
                // garbled geometry.
                return path
            }
        }
        return path
    }

    /// Splits an SVG path-data string into command letters and numeric
    /// tokens. Handles the compact-SVG cases where numbers run together
    /// without separators: `-` mid-token starts a new negative number,
    /// and a second `.` mid-token starts a new fractional number
    /// (e.g. `.3.4` → `["0.3", "0.4"]`).
    private static func tokenize(_ d: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        for ch in d {
            if ch.isLetter {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
                tokens.append(String(ch))
            } else if ch == " " || ch == "," || ch == "\n" || ch == "\t" || ch == "\r" {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            } else if ch == "-" && !cur.isEmpty
                        && !cur.hasSuffix("e") && !cur.hasSuffix("E") {
                tokens.append(cur); cur = String(ch)
            } else if ch == "." && cur.contains(".") {
                tokens.append(cur); cur = String(ch)
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { tokens.append(cur) }
        return tokens
    }
}
