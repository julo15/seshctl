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
        guard let contents = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return nil
        }
        return extractLatestAwaySummary(transcript: contents)
    }

    /// Pure, string-in form used by tests and callers that have the
    /// transcript content already in memory.
    public static func extractLatestAwaySummary(transcript: String) -> String? {
        // Only surface the recap when it's the most recent *meaningful* event
        // in the transcript. If a user or assistant turn lands after the
        // latest `away_summary`, the session has resumed and the recap is
        // stale — callers should fall through to lastReply/lastAsk instead
        // of pinning a row to a recap that no longer reflects current state.
        var pendingContent: String?
        transcript.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { return }
            if type == "system", obj["subtype"] as? String == "away_summary",
               let content = obj["content"] as? String {
                pendingContent = content
            } else if type == "user" || type == "assistant" {
                pendingContent = nil
            }
        }
        guard let raw = pendingContent else { return nil }
        let cleaned = stripRecapHint(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
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
