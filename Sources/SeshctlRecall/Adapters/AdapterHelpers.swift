// AdapterHelpers — internal utilities shared by the Claude / Codex / Gemini
// adapters. Kept deliberately small: ISO 8601 parsing (Claude + Gemini) and
// byte-offset-resumable JSONL iteration (Claude + Codex). Nothing here is
// public — the adapter implementations stay the only surface.

import Foundation

enum AdapterHelpers {
    /// Parse an ISO 8601 timestamp string into a unix-seconds `Double`.
    ///
    /// Matches the Python reference implementations'
    /// `datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()` shape:
    /// fractional-seconds variants land via the primary formatter, and the
    /// trailing-Z / no-fractional case falls back to the second formatter.
    /// Returns `0.0` on parse failure (Python convention).
    static func parseISO8601(_ string: String) -> Double {
        if string.isEmpty { return 0.0 }
        if let date = isoWithFractional.date(from: string) {
            return date.timeIntervalSince1970
        }
        if let date = isoBasic.date(from: string) {
            return date.timeIntervalSince1970
        }
        return 0.0
    }

    /// Write a warning line to stderr. Phase 6/8 may rewire this through
    /// `appendInstallLog`; for now, mirror the Python adapters' stderr prints
    /// so anomalies aren't swallowed during dev runs.
    static func warn(_ message: String) {
        let line = message.hasSuffix("\n") ? message : message + "\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    /// Iterate JSONL lines from `url` starting at byte `offset`, returning
    /// each line's raw text and the final byte offset reached. Skips empty
    /// lines silently (matches Python). The caller is responsible for JSON
    /// parsing — this helper only owns the file seek + line split so the
    /// cursor math lives in exactly one place.
    ///
    /// - Returns: `(lines, newOffset)` — `newOffset` is the post-read byte
    ///   position (the equivalent of Python's `f.tell()` after the for-loop).
    static func readJSONLines(
        url: URL,
        fromOffset offset: Int64
    ) throws -> (lines: [String], newOffset: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if offset > 0 {
            try handle.seek(toOffset: UInt64(offset))
        }
        let data = handle.readDataToEndOfFile()
        let newOffset = offset + Int64(data.count)
        guard let text = String(data: data, encoding: .utf8) else {
            return ([], newOffset)
        }
        // Match Python's `for line in f`: split on \n, trim each, drop empties.
        let lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (lines, newOffset)
    }

    // MARK: - Private state

    // ISO8601DateFormatter is documented as thread-safe (10.12+) but not
    // Sendable-annotated. `nonisolated(unsafe)` keeps the singletons callable
    // from the package's async contexts without rebuilding the formatter on
    // every call.
    private nonisolated(unsafe) static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
