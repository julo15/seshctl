import Foundation

/// Finds which model a session is running, by scanning its transcript.
///
/// The model isn't in the database — no hook payload carries it — so it has to
/// be read from the JSONL, which is why this follows the same
/// pure-Foundation-scanner shape as `TranscriptAwaySummaryScanner` and
/// `TranscriptLatestAssistantScanner`, with mtime caching applied by the caller.
///
/// **Per-tool availability**, which the row has to degrade around:
/// - **Claude Code** — every `assistant` record carries `message.model`, so a
///   value is essentially always available. Reads the most recent, since `/model`
///   can switch mid-session.
/// - **Codex** — only `model_change` records carry `modelId`, and a session that
///   never switches models never emits one. Sampling 546 real transcripts, most
///   had none. Returns nil there rather than guessing a default that would go
///   stale the moment Codex changed it.
/// - **Cursor / Gemini** — no transcript at all. Never reaches this scanner.
public enum TranscriptModelScanner {

    /// Scan a transcript on disk for the model in effect. Returns nil when the
    /// file can't be read or records no model.
    public static func extractModel(transcriptPath: String, tool: SessionTool) -> String? {
        guard let contents = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return nil
        }
        return extractModel(transcript: contents, tool: tool)
    }

    /// Pure, string-in form used by tests and by callers holding the transcript
    /// already.
    public static func extractModel(transcript: String, tool: SessionTool) -> String? {
        switch tool {
        case .claude:
            return scan(transcript) { obj in
                guard obj["type"] as? String == "assistant",
                      let message = obj["message"] as? [String: Any],
                      let model = message["model"] as? String,
                      // Claude writes `<synthetic>` for locally-generated
                      // messages (interrupts, errors) that never hit a model.
                      model != "<synthetic>"
                else { return nil }
                return model
            }
        case .codex:
            // Codex records the model in its `session_meta` header and in
            // `turn_context` events; both spell it `model`.
            return scan(transcript) { obj in
                guard let payload = obj["payload"] as? [String: Any] else { return nil }
                return payload["model"] as? String
            }
        case .pi:
            // Pi emits `model_change` whenever the provider or model switches,
            // including once at session start.
            return scan(transcript) { obj in
                guard obj["type"] as? String == "model_change" else { return nil }
                return obj["modelId"] as? String
            }
        case .gemini, .cursor:
            return nil
        }
    }

    /// Walk every line, keeping the last non-nil extraction. The *latest* model
    /// wins because both tools allow switching mid-session.
    private static func scan(
        _ transcript: String,
        // `enumerateLines` takes an escaping closure, so this has to escape too.
        extract: @escaping ([String: Any]) -> String?
    ) -> String? {
        var latest: String?
        transcript.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = extract(obj),
                  !value.isEmpty
            else { return }
            latest = value
        }
        return latest
    }

    /// Shorten a raw model id for the row subtitle, which shares one line with
    /// the agent name and branch.
    ///
    /// Strips the vendor prefix and any trailing date stamp — `claude-opus-5`
    /// becomes `Opus 5`, `gpt-5.3-codex` becomes `GPT-5.3`. Unrecognized ids
    /// pass through unchanged rather than being mangled, so a new model is
    /// merely verbose instead of wrong.
    public static func displayName(for rawModel: String) -> String {
        let model = rawModel.lowercased()

        // claude-opus-5, claude-sonnet-5, claude-haiku-4-5-20251001
        if model.hasPrefix("claude-") {
            var parts = model.dropFirst("claude-".count).split(separator: "-").map(String.init)
            // Drop a trailing yyyymmdd build stamp.
            if let last = parts.last, last.count == 8, Int(last) != nil {
                parts.removeLast()
            }
            guard let family = parts.first else { return rawModel }
            let version = parts.dropFirst().joined(separator: ".")
            let name = family.prefix(1).uppercased() + family.dropFirst()
            return version.isEmpty ? name : "\(name) \(version)"
        }

        // gpt-5.5, gpt-5.3-codex
        if model.hasPrefix("gpt-") {
            let trimmed = model.hasSuffix("-codex") ? String(model.dropLast("-codex".count)) : model
            return "GPT-" + trimmed.dropFirst("gpt-".count)
        }

        return rawModel
    }
}
