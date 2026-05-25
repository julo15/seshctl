import Foundation

/// Extracts the latest assistant text from a claude.ai
/// `/v1/code/sessions/<id>/events` response body, for use as a row preview
/// recap on pure-remote (Cowork) sessions — the remote analog of
/// `TranscriptAwaySummaryScanner` for local Claude Code JSONL transcripts.
///
/// The events endpoint returns a JSON object of the shape:
///
/// ```json
/// { "data": [ ...events newest-first..., ], "next_cursor": "1182" }
/// ```
///
/// Each event has an `event_type` (`"user"`, `"assistant"`, `"result"`, etc.)
/// and a `payload`. For `assistant` events, `payload.message.content` is an
/// array of content blocks; we want the first block whose `type == "text"`.
///
/// Response captures live under `.agents/spikes/claude-ai-cookie-spike/out/`.
public enum RemoteEventsParser {

    /// Extract the latest assistant text from a `/v1/code/sessions/<id>/events`
    /// response body. Returns the trimmed text body of the most recent
    /// assistant event's first `type == "text"` content block, preserving
    /// internal newlines — downstream display layers truncate visually via
    /// SwiftUI `.lineLimit(...)`.
    ///
    /// Returns `nil` when:
    /// - the body isn't a JSON object,
    /// - `data` is missing, not an array, or empty,
    /// - no event has `event_type == "assistant"`,
    /// - the first assistant event has no `type == "text"` content block, or
    /// - the matched text is empty after trimming wrapper whitespace.
    public static func extractLatestAssistantText(eventsResponseData: Data) -> String? {
        guard let parsed = try? JSONSerialization.jsonObject(with: eventsResponseData),
              let root = parsed as? [String: Any]
        else {
            return nil
        }
        guard let events = root["data"] as? [[String: Any]], !events.isEmpty else {
            return nil
        }
        // The events array is server-sorted newest-first (by `sequence_num`
        // descending), so the first assistant event we hit is the latest.
        for event in events {
            guard let type = event["event_type"] as? String, type == "assistant" else {
                continue
            }
            guard let payload = event["payload"] as? [String: Any],
                  let message = payload["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else {
                return nil
            }
            for block in content {
                guard let blockType = block["type"] as? String, blockType == "text",
                      let text = block["text"] as? String
                else {
                    continue
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return nil }
                return trimmed
            }
            // Newest assistant turn is tool_use-only (no text block). Deliberate:
            // older assistant text is stale once a newer turn has fired, so the
            // right UX is "no recap" rather than walking further back.
            return nil
        }
        return nil
    }
}
