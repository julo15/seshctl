import Foundation

/// Reads the thread names Codex keeps in `$CODEX_HOME/session_index.jsonl`.
///
/// Codex never writes a title into the rollout transcript itself. Instead it
/// appends one line per naming event to a single index beside `sessions/`:
///
/// ```json
/// {"id":"01a067af-…","thread_name":"what do you know about my job at gol","updated_at":"…"}
/// {"id":"01a067af-…","thread_name":"Describe Golfzon job knowledge","updated_at":"…"}
/// ```
///
/// The first line for a thread is the truncated opening prompt; a moment
/// later Codex appends the LLM-generated name, and an explicit rename appends
/// again. So the last line per `id` wins. `id` is the conversation id seshctl
/// already stores. (Codex also mirrors the name into `threads.name` in
/// `state_<N>.sqlite`, but the schema version is in the filename, so that
/// path breaks on Codex's next migration. The index is the stable surface.)
///
/// **Incremental.** The index is append-only and shared by every Codex
/// session, so `scan(indexPath:resuming:)` carries a byte offset in `State`
/// and reads only what was appended since, like `TranscriptTitleScanner`.
public enum CodexThreadNameIndex {

    public static let fileName = "session_index.jsonl"

    /// Scan progress for one index file: how far it has been read, and the
    /// latest name per conversation id seen so far.
    public struct State: Equatable, Sendable {
        /// Byte offset just past the last complete line scanned.
        public var offset: UInt64 = 0
        public var names: [String: String] = [:]

        public init(offset: UInt64 = 0, names: [String: String] = [:]) {
            self.offset = offset
            self.names = names
        }
    }

    /// The index that names the thread recorded in `rolloutPath`.
    ///
    /// Rollouts live at `<codex home>/sessions/YYYY/MM/DD/rollout-….jsonl`,
    /// so the index is found from the rollout path rather than from
    /// `$CODEX_HOME`, which the app (launched by launchd) can't see. Returns
    /// nil for any path not shaped like that.
    public static func indexPath(forRolloutPath rolloutPath: String) -> String? {
        let components = (rolloutPath as NSString).pathComponents
        guard components.count >= 6,
              components[components.count - 5] == "sessions",
              components[components.count - 1].hasPrefix("rollout-")
        else { return nil }
        let home = NSString.path(withComponents: Array(components.dropLast(5)))
        return (home as NSString).appendingPathComponent(fileName)
    }

    /// Continue scanning `indexPath` from `previous` (nil = from the start),
    /// reading only bytes appended since. A file shorter than
    /// `previous.offset` was rewritten, so it is rescanned from scratch. A
    /// trailing line without a newline may be mid-write, so the offset stops
    /// before it and it is read once complete. Returns nil when the file
    /// can't be opened.
    public static func scan(indexPath: String, resuming previous: State?) -> State? {
        guard let handle = FileHandle(forReadingAtPath: indexPath) else { return nil }
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
        guard let appended = try? handle.readToEnd(),
              let lastNewline = appended.lastIndex(of: newline)
        else { return state }
        let complete = appended[appended.startIndex...lastNewline]
        fold(complete, into: &state)
        state.offset += UInt64(complete.count)
        return state
    }

    private static let newline = UInt8(ascii: "\n")

    /// Fold every index line in `data` into `state`, last line per id winning.
    /// A blank name is skipped, so it never erases an earlier name.
    static func fold(_ data: Data, into state: inout State) {
        for line in data.split(separator: newline) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? String,
                  let name = (obj["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { continue }
            state.names[id] = name
        }
    }
}
