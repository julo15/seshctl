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
///
/// **Incremental.** Live transcripts run to 15 MB+ and change on every turn,
/// and the session list rescans on the main thread every refresh — a full
/// re-read cost ~115 ms per large file and made the panel visibly lag on
/// open/close. Transcripts are append-only, so `scan(transcriptPath:resuming:)`
/// carries a byte offset in `State` and reads only what was appended since.
/// Within the new bytes it byte-searches for the record marker rather than
/// splitting lines, so only title lines are ever decoded.
public enum TranscriptTitleScanner {

    /// Scan progress for one transcript: how far it has been read, and the
    /// latest title of each shape seen so far.
    public struct State: Equatable, Sendable {
        /// Byte offset just past the last complete line scanned.
        public var offset: UInt64 = 0
        public var aiTitle: String?
        public var customTitle: String?

        public init(offset: UInt64 = 0, aiTitle: String? = nil, customTitle: String? = nil) {
            self.offset = offset
            self.aiTitle = aiTitle
            self.customTitle = customTitle
        }

        /// The title to display — AI title, falling back to the custom title.
        public var title: String? { aiTitle ?? customTitle }
    }

    /// Scan a transcript file on disk for its session title. Returns `nil`
    /// when the file can't be read or has no non-empty title record.
    public static func extractTitle(transcriptPath: String) -> String? {
        scan(transcriptPath: transcriptPath, resuming: nil)?.title
    }

    /// Pure, string-in form used by tests and callers that have the
    /// transcript content already in memory.
    public static func extractTitle(transcript: String) -> String? {
        var state = State()
        scan(Data(transcript.utf8), into: &state)
        return state.title
    }

    /// Continue scanning `transcriptPath` from `previous` (nil = from the
    /// start), reading only bytes appended since. A file shorter than
    /// `previous.offset` was rewritten, so it is rescanned from scratch.
    /// A trailing partial line (mid-write) is left for the next scan.
    /// Returns nil when the file can't be opened.
    public static func scan(transcriptPath: String, resuming previous: State?) -> State? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        var state = previous ?? State()
        if state.offset > size {
            state = State()
        }
        guard state.offset < size else { return state }

        do {
            try handle.seek(toOffset: state.offset)
        } catch {
            return nil
        }
        guard let appended = try? handle.readToEnd(), !appended.isEmpty else { return state }

        // Advance the offset only through the last newline. A trailing line
        // without one may be mid-write, so it is re-read on the next scan —
        // but it is still applied now when it decodes as a whole record, so
        // a file whose final record lacks a newline isn't missed. Re-reading
        // it is idempotent: titles are last-record-wins.
        let tailStart = appended.lastIndex(of: newline).map { $0 + 1 } ?? appended.startIndex
        let complete = appended[appended.startIndex..<tailStart]
        scan(complete, into: &state)
        state.offset += UInt64(complete.count)
        let tail = appended[tailStart...]
        if tail.range(of: marker) != nil {
            apply(line: tail, to: &state)
        }
        return state
    }

    private static let newline = UInt8(ascii: "\n")
    private static let marker = Data("-title\"".utf8)

    /// Decode every line in `data` containing the title marker and fold any
    /// title records into `state`. Lines without the marker are never decoded.
    static func scan(_ data: Data, into state: inout State) {
        var searchStart = data.startIndex
        while searchStart < data.endIndex,
              let hit = data.range(of: marker, in: searchStart..<data.endIndex) {
            let lineStart = data[data.startIndex..<hit.lowerBound].lastIndex(of: newline).map { $0 + 1 } ?? data.startIndex
            let lineEnd = data[hit.upperBound...].firstIndex(of: newline) ?? data.endIndex
            apply(line: data[lineStart..<lineEnd], to: &state)
            searchStart = lineEnd
        }
    }

    private static func apply(line: Data, to state: inout State) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String
        else { return }
        switch type {
        case "ai-title":
            if let value = nonEmpty(obj["aiTitle"] as? String) { state.aiTitle = value }
        case "custom-title":
            if let value = nonEmpty(obj["customTitle"] as? String) { state.customTitle = value }
        default:
            break
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
