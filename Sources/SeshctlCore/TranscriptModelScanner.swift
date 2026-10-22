import Foundation

/// Finds which model a session is running by scanning its transcript. No hook
/// payload carries the model, so it has to come from the JSONL.
///
/// **Per-tool sources:**
/// - **Claude Code** — every `assistant` record carries `message.model`.
///   `<synthetic>` is skipped: Claude writes it for locally generated
///   messages (interrupts, errors) that never reached a model.
/// - **Codex** — `turn_context` records carry `payload.model`, one per turn.
/// - **Cursor / Gemini** — no transcript; always nil.
///
/// The newest record wins, since both tools can switch models mid-session.
/// Walks newest-first via `TranscriptReverseReader` and stops at the first
/// record that names a model, so a long transcript costs its last few KB.
public enum TranscriptModelScanner {

    /// Scan a transcript on disk for the model in effect. Returns nil when the
    /// file can't be read or records no model.
    public static func extractModel(transcriptPath: String, tool: SessionTool) -> String? {
        guard let step = step(for: tool) else { return nil }
        return TranscriptReverseReader.scan(transcriptPath: transcriptPath, visit: step)
    }

    /// Pure, string-in form used by tests.
    public static func extractModel(transcript: String, tool: SessionTool) -> String? {
        guard let step = step(for: tool) else { return nil }
        return TranscriptReverseReader.scan(transcript: transcript, visit: step)
    }

    private static func step(for tool: SessionTool) -> ((Data) -> TranscriptReverseReader.Step<String>)? {
        switch tool {
        case .claude: return claudeStep
        case .codex: return codexStep
        case .gemini, .cursor: return nil
        }
    }

    private static func claudeStep(_ line: Data) -> TranscriptReverseReader.Step<String> {
        guard let obj = decode(line), obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let model = message["model"] as? String,
              !model.isEmpty, model != "<synthetic>"
        else { return .skip }
        return .stop(model)
    }

    private static func codexStep(_ line: Data) -> TranscriptReverseReader.Step<String> {
        guard let obj = decode(line), obj["type"] as? String == "turn_context",
              let payload = obj["payload"] as? [String: Any],
              let model = payload["model"] as? String,
              !model.isEmpty
        else { return .skip }
        return .stop(model)
    }

    /// Lines that can't name a model are skipped before JSON decoding: most
    /// newest-first lines in a busy transcript are tool results, and some run
    /// to megabytes.
    private static let modelKey = Data("\"model\"".utf8)

    private static func decode(_ line: Data) -> [String: Any]? {
        guard line.range(of: modelKey) != nil else { return nil }
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    /// Shorten a raw model id for the row's model pill.
    ///
    /// Drops the vendor prefix, a trailing date stamp and a bracketed context
    /// tag: `claude-opus-5-5` → `Opus 5.5`, `claude-haiku-4-5-20251001` →
    /// `Haiku 4.5`, `claude-opus-4-6[1m]` → `Opus 4.6`, `gpt-5.3-codex` →
    /// `GPT-5.3`, `gpt-5.6-terra` → `GPT-5.6 Terra`. Unrecognized ids pass
    /// through unchanged, so a new model is verbose rather than wrong.
    public static func displayName(for rawModel: String) -> String {
        var model = rawModel.lowercased()
        if let bracket = model.firstIndex(of: "[") {
            model = String(model[..<bracket])
        }
        if model.hasPrefix("claude-") {
            var parts = model.dropFirst("claude-".count).split(separator: "-").map(String.init)
            if let last = parts.last, last.count == 8, Int(last) != nil {
                parts.removeLast()
            }
            guard let family = parts.first else { return rawModel }
            let version = parts.dropFirst().joined(separator: ".")
            let name = family.prefix(1).uppercased() + family.dropFirst()
            return version.isEmpty ? name : "\(name) \(version)"
        }
        if model.hasPrefix("gpt-") {
            var parts = model.dropFirst("gpt-".count).split(separator: "-").map(String.init)
            if parts.last == "codex" { parts.removeLast() }
            guard let version = parts.first else { return rawModel }
            let variant = parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return (["GPT-" + version] + variant).joined(separator: " ")
        }
        return rawModel
    }
}
