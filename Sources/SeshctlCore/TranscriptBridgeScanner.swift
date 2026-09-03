import Foundation

/// Finds the cse_id of the claude.ai Code-tab session a local CLI transcript
/// is bridged to.
///
/// Claude Code CLI writes an explicit event to its JSONL transcript when
/// bridging is enabled. Two shapes have shipped over time and both are
/// recognized here:
///
/// **Current shape** — a dedicated record carrying the API id directly:
///
/// ```json
/// {"type":"bridge-session","sessionId":"<local uuid>",
///  "bridgeSessionId":"cse_<SUFFIX>","lastSequenceNum":0, ...}
/// ```
///
/// **Legacy shape** — a system event carrying the web URL:
///
/// ```json
/// {"type":"system","subtype":"bridge_status",
///  "content":"/remote-control is active. Code in CLI or at https://claude.ai/code/session_<SUFFIX>",
///  "url":"https://claude.ai/code/session_<SUFFIX>",
///  ...}
/// ```
///
/// The web URL's `session_<SUFFIX>` form is the same suffix the claude.ai
/// API returns as `cse_<SUFFIX>`. Converting between the two gives a
/// deterministic local <-> remote join — no heuristics needed. The current
/// shape skips the conversion by emitting the `cse_`-prefixed id verbatim.
///
/// Both shapes are still scanned because a transcript written by an older
/// CLI (or resumed across a CLI upgrade) can contain either. Whichever
/// event appears last in the file wins.
///
/// This scanner is the source of truth for the `local.id -> cse_id` mapping
/// used by `BridgeMatcher`.
public enum TranscriptBridgeScanner {

    /// Scan a transcript file on disk for its most recent bridge event
    /// (either shape). The last *valid* bridge record wins: a malformed or
    /// id-less record (e.g. a `bridge-session` line with `bridgeSessionId`
    /// missing) is skipped rather than clearing an id found earlier in the
    /// file. Staleness isn't this scanner's job — `BridgeMatcher` checks the
    /// returned id against the live API-supplied remote ids, so an id that
    /// outlived its bridge is inert.
    ///
    /// Returns `nil` when:
    /// - the file can't be read,
    /// - the transcript never bridged.
    public static func extractBridgedRemoteId(transcriptPath: String) -> String? {
        guard let contents = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return nil
        }
        return extractBridgedRemoteId(transcript: contents)
    }

    /// Pure, string-in form used by tests and callers that have the
    /// transcript content already in memory.
    public static func extractBridgedRemoteId(transcript: String) -> String? {
        var latestCseId: String?
        transcript.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { return }
            switch type {
            case "bridge-session":
                // Current shape: the API id is already `cse_`-prefixed.
                guard let raw = obj["bridgeSessionId"] as? String,
                      let cseId = normalizedCseId(raw)
                else { return }
                latestCseId = cseId
            case "system":
                // Legacy shape: derive the id from the claude.ai web URL.
                guard obj["subtype"] as? String == "bridge_status",
                      let url = obj["url"] as? String,
                      let cseId = cseId(fromWebUrl: url)
                else { return }
                latestCseId = cseId
            default:
                return
            }
        }
        return latestCseId
    }

    /// Normalize a `bridgeSessionId` into the API-native `cse_<SUFFIX>` form.
    /// The field ships already prefixed, but tolerating a bare suffix keeps
    /// the join working if the CLI ever drops the prefix. Empty (or
    /// prefix-only) values return `nil` so they can't pair with a remote.
    static func normalizedCseId(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("cse_") else { return "cse_\(trimmed)" }
        return trimmed.count > "cse_".count ? trimmed : nil
    }

    /// Convert `https://claude.ai/code/session_<SUFFIX>` (or a relative
    /// variant) into the API-native `cse_<SUFFIX>` identifier. Returns
    /// `nil` on any other URL shape.
    static func cseId(fromWebUrl url: String) -> String? {
        let marker = "/code/session_"
        guard let range = url.range(of: marker) else { return nil }
        let tail = url[range.upperBound...]
        // Trim any trailing path, query, or fragment.
        let suffix = tail.split(whereSeparator: { "/?#".contains($0) }).first
        guard let suffixStr = suffix.map(String.init), !suffixStr.isEmpty else {
            return nil
        }
        return "cse_\(suffixStr)"
    }
}
