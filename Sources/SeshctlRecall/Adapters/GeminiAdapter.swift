// GeminiAdapter — port of `recall/adapters/gemini.py`.
//
// Gemini stores each conversation as a JSON array (not JSONL) at
// `~/.gemini/tmp/<session>/logs.json`, with the project root in a sibling
// `.project_root` file. There's no byte-offset cursor — instead we maintain
// a `(sessionId, messageId)` dedup set; new runs walk every file but only
// emit unseen messages. The cursor is JSON-encoded `{ "seen": [[s, m], ...] }`.
//
// Non-`user` messages and empty-text messages are skipped, but their keys are
// still added to `seen` so a later run doesn't re-evaluate them.

import Foundation

public struct GeminiAdapter: Adapter {
    public let name = "gemini"

    /// JSON shape: `{ "seen": [["session", "messageId"], ...] }`.
    public struct GeminiCursor: Codable, Equatable {
        public var seen: [[String]]

        public init(seen: [[String]] = []) {
            self.seen = seen
        }
    }

    private let baseDir: URL

    public init(baseDir: URL? = nil) {
        if let baseDir {
            self.baseDir = baseDir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.baseDir = home.appendingPathComponent(".gemini/tmp", isDirectory: true)
        }
    }

    public func load(cursor: Data?) async throws -> (entries: [HistoryEntry], newCursor: Data) {
        let fm = FileManager.default
        let cursorValue = Self.decodeCursor(cursor)
        var seen: Set<KeyPair> = Set(cursorValue.seen.compactMap { pair -> KeyPair? in
            guard pair.count == 2 else { return nil }
            return KeyPair(session: pair[0], message: pair[1])
        })
        var entries: [HistoryEntry] = []

        guard fm.fileExists(atPath: baseDir.path) else {
            return ([], Self.encodeCursor(GeminiCursor(seen: Self.encodeSeen(seen))))
        }

        let sessionDirs: [URL]
        do {
            sessionDirs = try fm.contentsOfDirectory(
                at: baseDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return ([], Self.encodeCursor(GeminiCursor(seen: Self.encodeSeen(seen))))
        }

        for dir in sessionDirs {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: dir.path, isDirectory: &isDir) || !isDir.boolValue {
                continue
            }
            let logsFile = dir.appendingPathComponent("logs.json")
            guard fm.fileExists(atPath: logsFile.path) else { continue }

            let data: Data
            do {
                data = try Data(contentsOf: logsFile)
            } catch {
                AdapterHelpers.warn("warning: skipping corrupted file \(logsFile.path)")
                continue
            }
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: data, options: [])
            } catch {
                AdapterHelpers.warn("warning: skipping corrupted file \(logsFile.path)")
                continue
            }
            guard let messages = parsed as? [Any] else { continue }

            // Sibling .project_root file.
            var project = ""
            let projectRootFile = dir.appendingPathComponent(".project_root")
            if fm.fileExists(atPath: projectRootFile.path) {
                if let text = try? String(contentsOf: projectRootFile, encoding: .utf8) {
                    project = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            for raw in messages {
                guard let msg = raw as? [String: Any] else { continue }
                let sessionID = (msg["sessionId"] as? String) ?? ""
                let messageIDString = Self.stringForMessageID(msg["messageId"])
                let key = KeyPair(session: sessionID, message: messageIDString)

                if seen.contains(key) { continue }

                let type = msg["type"] as? String ?? ""
                if type != "user" {
                    seen.insert(key)
                    continue
                }

                let text = (msg["message"] as? String) ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    seen.insert(key)
                    continue
                }

                let timestampString = (msg["timestamp"] as? String) ?? ""
                let timestamp = AdapterHelpers.parseISO8601(timestampString)

                entries.append(
                    HistoryEntry(
                        agent: name,
                        role: "user",
                        sessionID: sessionID,
                        project: project,
                        timestamp: timestamp,
                        text: text,
                        textHash: HistoryEntry.textHash(for: text)
                    )
                )
                seen.insert(key)
            }
        }

        let newCursor = GeminiCursor(seen: Self.encodeSeen(seen))
        return (entries, Self.encodeCursor(newCursor))
    }

    // MARK: - Helpers

    /// Stringify Python's `messageId`, which may be int or string. Python's
    /// `str(0)` is `"0"`; we mirror that.
    static func stringForMessageID(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            // Integer-like — match Python's `str(int)` formatting.
            if CFNumberIsFloatType(n) {
                return String(n.doubleValue)
            }
            return String(n.int64Value)
        }
        if let i = value as? Int { return String(i) }
        if let d = value as? Double { return String(d) }
        return "0"
    }

    static func decodeCursor(_ data: Data?) -> GeminiCursor {
        guard let data, !data.isEmpty else { return GeminiCursor() }
        if let decoded = try? JSONDecoder().decode(GeminiCursor.self, from: data) {
            return decoded
        }
        return GeminiCursor()
    }

    static func encodeCursor(_ cursor: GeminiCursor) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(cursor)) ?? Data()
    }

    /// Sort the seen set into a deterministic `[[session, msg], ...]` array.
    static func encodeSeen(_ set: Set<KeyPair>) -> [[String]] {
        set.map { [$0.session, $0.message] }
            .sorted { lhs, rhs in
                if lhs[0] != rhs[0] { return lhs[0] < rhs[0] }
                return lhs[1] < rhs[1]
            }
    }

    /// Tuple-shaped dedup key. Hashable for Set storage.
    struct KeyPair: Hashable {
        let session: String
        let message: String
    }
}
