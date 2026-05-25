// CodexAdapter — port of `recall/adapters/codex.py`.
//
// Codex's history is one append-only JSONL file (`~/.codex/history.jsonl`).
// Each line is `{ "session_id", "ts", "text" }`. We resume on a single byte
// offset; the cursor is `{"offset": Int64}` JSON-encoded.
//
// Missing file is not an error — we return no entries and pass the cursor
// through unchanged (matches Python).

import Foundation

public struct CodexAdapter: Adapter {
    public let name = "codex"

    /// Single-file byte-offset cursor.
    public struct CodexCursor: Codable, Equatable {
        public var offset: Int64

        public init(offset: Int64 = 0) {
            self.offset = offset
        }
    }

    private let historyPath: URL

    public init(historyPath: URL? = nil) {
        if let historyPath {
            self.historyPath = historyPath
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.historyPath = home.appendingPathComponent(".codex/history.jsonl")
        }
    }

    public func load(cursor: Data?) async throws -> (entries: [HistoryEntry], newCursor: Data) {
        let fm = FileManager.default
        var current = Self.decodeCursor(cursor)

        guard fm.fileExists(atPath: historyPath.path) else {
            return ([], Self.encodeCursor(current))
        }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: historyPath.path)
        } catch {
            return ([], Self.encodeCursor(current))
        }
        guard let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return ([], Self.encodeCursor(current))
        }
        if current.offset >= size {
            return ([], Self.encodeCursor(current))
        }

        let read: (lines: [String], newOffset: Int64)
        do {
            read = try AdapterHelpers.readJSONLines(
                url: historyPath,
                fromOffset: current.offset
            )
        } catch {
            AdapterHelpers.warn("warning: failed to read \(historyPath.path): \(error)")
            return ([], Self.encodeCursor(current))
        }

        var entries: [HistoryEntry] = []
        for line in read.lines {
            guard let lineData = line.data(using: .utf8) else { continue }
            let json: Any
            do {
                json = try JSONSerialization.jsonObject(with: lineData, options: [])
            } catch {
                AdapterHelpers.warn(
                    "warning: skipping corrupted line in \(historyPath.path)"
                )
                continue
            }
            guard let dict = json as? [String: Any] else { continue }

            let text = (dict["text"] as? String) ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            let sessionID = (dict["session_id"] as? String) ?? ""
            let timestamp: Double
            if let n = dict["ts"] as? NSNumber {
                timestamp = n.doubleValue
            } else if let d = dict["ts"] as? Double {
                timestamp = d
            } else if let i = dict["ts"] as? Int {
                timestamp = Double(i)
            } else {
                timestamp = 0.0
            }

            entries.append(
                HistoryEntry(
                    agent: name,
                    role: "user",
                    sessionID: sessionID,
                    project: "",
                    timestamp: timestamp,
                    text: text,
                    textHash: HistoryEntry.textHash(for: text)
                )
            )
        }

        current.offset = read.newOffset
        return (entries, Self.encodeCursor(current))
    }

    // MARK: - Cursor codec

    static func decodeCursor(_ data: Data?) -> CodexCursor {
        guard let data, !data.isEmpty else { return CodexCursor() }
        if let decoded = try? JSONDecoder().decode(CodexCursor.self, from: data) {
            return decoded
        }
        return CodexCursor()
    }

    static func encodeCursor(_ cursor: CodexCursor) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(cursor)) ?? Data()
    }
}
