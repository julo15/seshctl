import Foundation

/// Finds the most recent `away_summary` Claude Code emits to its JSONL
/// transcript when summarizing what happened while the user was away.
///
/// Claude Code CLI writes these events directly to the transcript:
///
/// ```json
/// {"type":"system","subtype":"away_summary",
///  "content":"Shipped two PRs to main today: #31 and #32. (disable recaps in /config)",
///  "timestamp":"2026-05-06T17:48:04.022Z",
///  ...}
/// ```
///
/// The content always ends with a `(disable recaps in /config)` parenthetical
/// that Claude Code appends as a hint to the user. We strip it at the source
/// so downstream callers (row display, notifications, etc.) get clean text.
public enum TranscriptAwaySummaryScanner {

    /// Scan a transcript file on disk for its most recent `away_summary`
    /// event. Returns `nil` when:
    /// - the file can't be read,
    /// - the transcript has no `away_summary` events,
    /// - the most recent event has no `content` field, or its content is
    ///   empty after stripping the trailing recap hint.
    public static func extractLatestAwaySummary(transcriptPath: String) -> String? {
        // Newest-first walk via `TranscriptReverseReader`: stops at the first
        // decisive line, so a 15 MB transcript costs its last few KB rather
        // than a full decode on every refresh.
        TranscriptReverseReader.scan(transcriptPath: transcriptPath, visit: step) ?? nil
    }

    /// Pure, string-in form used by tests and callers that have the
    /// transcript content already in memory.
    public static func extractLatestAwaySummary(transcript: String) -> String? {
        TranscriptReverseReader.scan(transcript: transcript, visit: step) ?? nil
    }

    /// Only surface the recap when it's the most recent *meaningful* event
    /// in the transcript. Read newest-first: a user or assistant turn seen
    /// before any recap means the session has resumed and any older recap is
    /// stale — callers should fall through to lastReply/lastAsk instead of
    /// pinning a row to a recap that no longer reflects current state.
    private static func step(_ line: Data) -> TranscriptReverseReader.Step<String?> {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String
        else { return .skip }
        if type == "system", obj["subtype"] as? String == "away_summary",
           let content = obj["content"] as? String {
            let cleaned = stripRecapHint(content).trimmingCharacters(in: .whitespacesAndNewlines)
            return .stop(cleaned.isEmpty ? nil : cleaned)
        }
        if type == "user" || type == "assistant" {
            return .stop(nil)
        }
        return .skip
    }

    /// Strip the trailing `(disable recaps in /config)` parenthetical Claude
    /// Code appends to every `away_summary`. Whitespace-tolerant: any amount
    /// of whitespace before the parenthetical is consumed.
    static func stripRecapHint(_ content: String) -> String {
        let marker = "(disable recaps in /config)"
        let trimmedTail = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTail.hasSuffix(marker) else { return content }
        let withoutMarker = String(trimmedTail.dropLast(marker.count))
        return withoutMarker.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
