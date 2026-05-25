import Foundation

/// Finds the most recent assistant text block in a Claude Code JSONL
/// transcript, for use as a live row preview recap on local sessions while
/// a long response is mid-stream (before the `Stop` hook fires and populates
/// `lastReply`).
///
/// Sibling of `TranscriptAwaySummaryScanner` (same mtime-cache pattern,
/// same "current state" framing) and the local-side analog of
/// `RemoteEventsParser` (same content-block walking, same tool-use-only →
/// nil rule).
///
/// Claude Code writes each conversation event as one line of JSON. An
/// assistant turn looks like:
///
/// ```json
/// {"type":"assistant","message":{"role":"assistant","content":[
///   {"type":"thinking","thinking":"...","signature":"..."},
///   {"type":"text","text":"..."},
///   {"type":"tool_use","name":"Read","input":{}}
/// ]},"timestamp":"...","sessionId":"..."}
/// ```
///
/// Two state-machine rules govern when the scanner returns a value:
///
/// 1. **Tool-use-only → nil.** If the newest assistant turn has no `text`
///    block (only `thinking` / `tool_use`), return nil — do NOT walk back to
///    an older text-bearing turn. Older assistant text is stale once a new
///    turn has fired; the right UX is "no recap" rather than a misleading
///    one. Matches `RemoteEventsParser`'s documented behavior.
/// 2. **User-turn-clears-pending → nil.** If a `user` event lands after the
///    latest assistant text, the user has queued a new prompt and the recap
///    is stale. Return nil so callers fall through to `lastAsk` (the row
///    shows `You: <new prompt>` instead of stale assistant text). Mirrors
///    `TranscriptAwaySummaryScanner`'s "current state" invalidation.
public enum TranscriptLatestAssistantScanner {

    /// Scan a transcript file on disk for the most recent assistant text
    /// block. Returns `nil` when the file can't be read or no assistant
    /// text qualifies under the two state-machine rules above.
    public static func extractLatestAssistantText(transcriptPath: String) -> String? {
        guard let contents = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return nil
        }
        return extractLatestAssistantText(transcript: contents)
    }

    /// Pure, string-in form used by tests and callers that have the
    /// transcript content already in memory.
    public static func extractLatestAssistantText(transcript: String) -> String? {
        var pendingText: String?
        transcript.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { return }
            if type == "assistant" {
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]]
                else {
                    pendingText = nil
                    return
                }
                var found: String?
                for block in content {
                    guard let blockType = block["type"] as? String, blockType == "text",
                          let text = block["text"] as? String
                    else { continue }
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        found = text
                    }
                    break
                }
                pendingText = found
            } else if type == "user" {
                pendingText = nil
            }
        }
        guard let raw = pendingText else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
