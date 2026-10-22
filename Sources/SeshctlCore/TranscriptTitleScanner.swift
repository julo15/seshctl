import Foundation

/// Finds the short session title Claude Code writes to its JSONL transcript.
///
/// Claude Code emits two title-bearing record shapes:
///
/// ```json
/// {"type":"ai-title","aiTitle":"Sign in with Apple setup","sessionId":"..."}
/// {"type":"custom-title","customTitle":"m5: assistant","sessionId":"..."}
/// ```
///
/// `ai-title` is an LLM-generated 3–6 word label derived from the opening
/// prompt; Claude Code writes it once and re-appends the same value, so it
/// does not track later drift in the conversation. `custom-title` is set by
/// an explicit rename (and by remote-control session naming).
///
/// The AI title wins when both are present: custom titles in practice are
/// often machine-prefixed names (`m5: assistant`) that identify the host,
/// not what the session is doing. The custom title is the fallback for
/// sessions that never got an AI title. Within each shape, the last record
/// in the file wins.
public enum TranscriptTitleScanner {

    /// Scan a transcript file on disk for its session title. Returns `nil`
    /// when the file can't be read or has no non-empty title record.
    public static func extractTitle(transcriptPath: String) -> String? {
        guard let contents = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return nil
        }
        return extractTitle(transcript: contents)
    }

    /// Pure, string-in form used by tests and callers that have the
    /// transcript content already in memory.
    public static func extractTitle(transcript: String) -> String? {
        var aiTitle: String?
        var customTitle: String?
        transcript.enumerateLines { line, _ in
            // Cheap substring pre-filter: transcripts run to thousands of
            // lines and only a handful are title records, so skip JSON
            // decoding for everything else.
            guard line.contains("-title\"") else { return }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { return }
            switch type {
            case "ai-title":
                if let value = nonEmpty(obj["aiTitle"] as? String) { aiTitle = value }
            case "custom-title":
                if let value = nonEmpty(obj["customTitle"] as? String) { customTitle = value }
            default:
                break
            }
        }
        return aiTitle ?? customTitle
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
