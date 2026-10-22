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
/// Turn boundaries for this scanner are *fresh-prompt* `user` events
/// only; `tool_result`-only user events are mid-turn continuations and
/// don't reset the state machine (see Rule 2 below for the precise
/// content-shape check). Consecutive `assistant` events with no
/// intervening fresh-prompt `user` event are sub-events of the same
/// logical turn, even if the trailing event is tool_use-only.
///
/// State-machine rules:
///
/// 1. **Latest text within a turn wins.** Each `assistant` event with a
///    non-empty `text` block updates `pendingText`. Events without a text
///    block (thinking-only / tool_use-only) leave `pendingText` alone —
///    they're sub-events of the same turn, not new turns. This is what
///    makes the AskUserQuestion case work: the trailing tool_use sub-event
///    no longer clobbers the narration that preceded it.
/// 2. **Fresh-prompt user events clear; tool_result continuations don't.**
///    Claude Code uses `type:"user"` for two distinct things: real fresh
///    prompts from the human, and tool_result continuations that the harness
///    streams back to the assistant mid-turn. Only the first is a real turn
///    boundary. Fresh prompts (`message.content` is a string, or an array
///    containing any text/image/etc. block, or missing/malformed) clear
///    `pendingText` so callers fall through to `lastAsk` (the row shows
///    `You: <new prompt>` instead of stale assistant text — mirrors
///    `TranscriptAwaySummaryScanner`'s "current state" invalidation).
///    Tool_result-only continuations (`message.content` is a non-empty array
///    whose every block is `tool_result`) leave `pendingText` alone: Claude
///    is still mid-turn, the human didn't do anything, and the row preview
///    should keep showing the latest assistant narration until the next text
///    block lands.
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
    ///
    /// Walks lines newest-first via `TranscriptReverseReader` and stops at
    /// the first decisive line — equivalent to the forward state machine,
    /// whose final state is set by the newest line that changes it — so a
    /// 15 MB transcript costs its last few KB, not a full decode.
    public static func extractLatestAssistantText(transcriptPath: String) -> String? {
        TranscriptReverseReader.scan(transcriptPath: transcriptPath, visit: step) ?? nil
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
        TranscriptReverseReader.scan(transcript: transcript, visit: step) ?? nil
    }

    /// The forward state machine's transitions, read newest-first: the first
    /// line (from the end) that would set or clear `pendingText` decides.
    /// - assistant event with a non-empty text block → that text.
    /// - `user` event that is a fresh prompt → nil (no pending reply).
    /// - everything else (tool_result-only `user` continuations, assistant
    ///   turns with no text, other record types, malformed lines) → skip.
    private static func step(_ line: Data) -> TranscriptReverseReader.Step<String?> {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String
        else { return .skip }
        if type == "assistant" {
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { return .skip }
            for block in content {
                guard let blockType = block["type"] as? String, blockType == "text",
                      let text = block["text"] as? String
                else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                return .stop(trimmed)
            }
            return .skip
        }
        if type == "user" {
            // A `user` event is only a real turn boundary when it carries
            // a fresh prompt. Claude Code also emits `type:"user"` for
            // tool_result continuations mid-turn (the assistant fires a
            // tool_use, the harness streams back the result as a user
            // event) — those aren't turn boundaries, so they must NOT
            // clobber the pending reply. Distinguish by inspecting
            // `message.content`: an array whose every block is
            // `tool_result` is a continuation; anything else (string
            // content, array with text/image/etc., missing/malformed) is
            // treated as a fresh prompt and clears.
            if let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]],
               !content.isEmpty,
               content.allSatisfy({ ($0["type"] as? String) == "tool_result" })
            {
                return .skip
            }
            return .stop(nil)
        }
        return .skip
    }
}
