import Foundation

/// Finds the most recent assistant text block in a Claude Code JSONL
/// transcript, for use as a live row preview recap on local sessions while
/// a long response is mid-stream (before the `Stop` hook fires and populates
/// `lastReply`).
///
/// Sibling of `TranscriptAwaySummaryScanner` (same mtime-cache pattern,
/// same "current state" framing).
///
/// Claude Code writes the conversation as one JSONL line per content block —
/// a single logical assistant turn fans out into multiple `assistant`
/// records, each carrying one of `thinking` / `text` / `tool_use`, in the
/// order the model emitted them. A complete `AskUserQuestion` turn might
/// look like:
///
/// ```json
/// {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking",...}]}}
/// {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I've got enough..."}]}}
/// {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion",...}]}}
/// ```
///
/// Turn boundaries are `user` events (either a fresh prompt or a
/// `tool_result`-bearing user message). Consecutive `assistant` events
/// with no intervening `user` event are sub-events of the same logical
/// turn, even if the trailing event is tool_use-only.
///
/// State-machine rules:
///
/// 1. **Latest text within a turn wins.** Each `assistant` event with a
///    non-empty `text` block updates `pendingText`. Events without a text
///    block (thinking-only / tool_use-only) leave `pendingText` alone —
///    they're sub-events of the same turn, not new turns. This is what
///    makes the AskUserQuestion case work: the trailing tool_use sub-event
///    no longer clobbers the narration that preceded it.
/// 2. **User-turn-clears-pending → nil.** A `user` event marks a turn
///    boundary. Clear `pendingText` so callers fall through to `lastAsk`
///    (the row shows `You: <new prompt>` instead of stale assistant text).
///    Mirrors `TranscriptAwaySummaryScanner`'s "current state" invalidation.
/// 3. **System events preserve pendingText.** `system` events (including
///    `system/away_summary`) deliberately do NOT clear pendingText — only
///    `user` events do. This asymmetry is what lets the consumer-side
///    `awaySummariesById ?? latestAssistantById` collapse work: when Claude
///    emits an away_summary after assistant text, both scanners produce a
///    value for the same session and the collapse picks `awaySummary` first.
///    Test `returnsLatestAssistantWhenAwaySummaryFollowsIt` pins this.
/// 4. **Malformed assistant events are skipped.** If `message.content` is
///    missing or the wrong shape, leave `pendingText` alone rather than
///    clearing it — matches the policy already used for non-JSON lines
///    (`skipsMalformedLinesAndKeepsScanning`).
public enum TranscriptLatestAssistantScanner {

    /// Scan a transcript file on disk for the most recent assistant text
    /// block. Returns `nil` when the file can't be read or no assistant
    /// text qualifies under the state-machine rules above.
    public static func extractLatestAssistantText(transcriptPath: String) -> String? {
        guard let contents = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return nil
        }
        return extractLatestAssistantText(transcript: contents)
    }

    /// Pure, string-in form used by tests and callers that have the
    /// transcript content already in memory.
    ///
    /// Inner-loop note: within a single assistant event, the FIRST
    /// non-empty `text` block wins. Empty / whitespace-only text blocks are
    /// skipped (don't clear `pendingText`). Today's Claude Code JSONL emits
    /// exactly one text block per assistant event, so this is mostly
    /// theoretical — but the "skip empty, keep scanning" rule is the safer
    /// choice if Claude ever starts emitting `[empty-text, real-text]`
    /// shapes.
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
                else { return }
                for block in content {
                    guard let blockType = block["type"] as? String, blockType == "text",
                          let text = block["text"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    pendingText = text
                    break
                }
            } else if type == "user" {
                pendingText = nil
            }
        }
        guard let raw = pendingText else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
