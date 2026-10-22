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
        if case .text(let text) = scanPage(eventsResponseData: eventsResponseData) {
            return text
        }
        return nil
    }

    /// Outcome of scanning one page of the events endpoint, newest-first.
    public enum PageScan: Equatable, Sendable {
        /// The newest assistant event on the page has this text.
        case text(String)
        /// The newest assistant event has no usable text (tool_use-only,
        /// empty, or a malformed message). Paging stops: older assistant
        /// text is stale once a newer turn has fired.
        case assistantWithoutText
        /// No assistant event on this page — only system / control events.
        /// Remote-control sessions write a `system/init` event on every
        /// reconnect, so a whole page of them is normal; the caller should
        /// fetch the older page at `nextCursor` (nil = no older page).
        case noAssistant(nextCursor: String?)
        /// The body isn't an events response at all (schema drift).
        case malformed
    }

    /// Scan one events page. See `PageScan` for the outcomes.
    /// `extractLatestAssistantText(eventsResponseData:)` is the single-page
    /// convenience; `RemoteClaudeCodeFetcher` pages with this.
    public static func scanPage(eventsResponseData: Data) -> PageScan {
        guard let parsed = try? JSONSerialization.jsonObject(with: eventsResponseData),
              let root = parsed as? [String: Any],
              let events = root["data"] as? [[String: Any]]
        else {
            return .malformed
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
                return .assistantWithoutText
            }
            for block in content {
                guard let blockType = block["type"] as? String, blockType == "text",
                      let text = block["text"] as? String
                else {
                    continue
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? .assistantWithoutText : .text(trimmed)
            }
            // Newest assistant turn is tool_use-only (no text block). Deliberate:
            // older assistant text is stale once a newer turn has fired, so the
            // right UX is "no recap" rather than walking further back.
            return .assistantWithoutText
        }
        return .noAssistant(nextCursor: cursorString(root["next_cursor"]))
    }

    /// `next_cursor` is a sequence number; accept it as a JSON string or
    /// number so a server-side type change doesn't silently stop paging.
    static func cursorString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
