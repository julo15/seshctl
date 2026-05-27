// ClaudeAdapter — port of `recall/adapters/claude.py`.
//
// Walks `~/.claude/projects/*/*.jsonl` (one JSONL per conversation) and emits
// one `HistoryEntry` per user-prompt-or-assistant-text turn after tag-stripping.
// The cursor is a JSON-encoded `[file path → ClaudeFileCursor]` map mirroring
// the Python implementation's `{offset, cwd}` per-file dict so we can resume
// mid-file across runs.
//
// Empty cursor (`nil` or zero bytes) means "first run" — every file is read
// from byte 0. Subsequent runs only read newly-appended bytes.

import Foundation

public struct ClaudeAdapter: Adapter {
    public let name = "claude"

    /// Per-file resumable cursor. `offset` is the byte offset reached on the
    /// previous run; `cwd` is sticky across runs because Claude's transcripts
    /// only record `cwd` on the first user-prompt line.
    public struct ClaudeFileCursor: Codable, Equatable {
        public var offset: Int64
        public var cwd: String?

        public init(offset: Int64 = 0, cwd: String? = nil) {
            self.offset = offset
            self.cwd = cwd
        }
    }

    private let projectsDir: URL

    public init(projectsDir: URL? = nil) {
        if let projectsDir {
            self.projectsDir = projectsDir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.projectsDir = home.appendingPathComponent(".claude/projects", isDirectory: true)
        }
    }

    public func load(cursor: Data?) async throws -> (entries: [HistoryEntry], newCursor: Data) {
        var fileCursors = Self.decodeCursor(cursor)
        var entries: [HistoryEntry] = []

        let transcripts = transcriptFiles()
        for transcriptURL in transcripts {
            let key = transcriptURL.path
            var fileCursor = fileCursors[key] ?? ClaudeFileCursor()

            // Stat for size; skip if file unreadable.
            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)
            } catch {
                continue
            }
            guard let size = (attrs[.size] as? NSNumber)?.int64Value else { continue }
            if fileCursor.offset >= size { continue }

            let sessionID = transcriptURL.deletingPathExtension().lastPathComponent
            var fileEntries: [(role: String, text: String, timestamp: Double)] = []

            let read: (lines: [String], newOffset: Int64)
            do {
                read = try AdapterHelpers.readJSONLines(
                    url: transcriptURL,
                    fromOffset: fileCursor.offset
                )
            } catch {
                AdapterHelpers.warn("warning: failed to read \(transcriptURL.path): \(error)")
                continue
            }

            for line in read.lines {
                guard let lineData = line.data(using: .utf8) else { continue }
                let json: Any
                do {
                    json = try JSONSerialization.jsonObject(with: lineData, options: [])
                } catch {
                    AdapterHelpers.warn(
                        "warning: skipping corrupted line in \(transcriptURL.path)"
                    )
                    continue
                }
                guard let data = json as? [String: Any] else { continue }

                // Capture cwd from first line that has it (matches Python).
                if fileCursor.cwd == nil, let cwd = data["cwd"] as? String, !cwd.isEmpty {
                    fileCursor.cwd = cwd
                }

                let entryType = data["type"] as? String ?? ""
                let message = data["message"] as? [String: Any] ?? [:]
                let timestampString = data["timestamp"] as? String ?? ""
                let timestamp = AdapterHelpers.parseISO8601(timestampString)

                if entryType == "user" {
                    if let text = Self.extractUserText(message: message) {
                        let cleaned = Self.stripTags(text)
                        if !cleaned.isEmpty {
                            fileEntries.append((role: "user", text: cleaned, timestamp: timestamp))
                        }
                    }
                } else if entryType == "assistant" {
                    if let text = Self.extractAssistantText(message: message) {
                        let cleaned = Self.stripTags(text)
                        if !cleaned.isEmpty {
                            fileEntries.append(
                                (role: "assistant", text: cleaned, timestamp: timestamp)
                            )
                        }
                    }
                }
            }

            fileCursor.offset = read.newOffset

            // Resolve project: prefer cwd, else decoded dir name.
            let project: String
            if let cwd = fileCursor.cwd, !cwd.isEmpty {
                project = cwd
            } else {
                project = Self.decodeProjectDir(
                    transcriptURL.deletingLastPathComponent().lastPathComponent
                )
            }

            for fe in fileEntries {
                let entry = HistoryEntry(
                    agent: name,
                    role: fe.role,
                    sessionID: sessionID,
                    project: project,
                    timestamp: fe.timestamp,
                    text: fe.text,
                    textHash: HistoryEntry.textHash(for: fe.text)
                )
                entries.append(entry)
            }

            fileCursors[key] = fileCursor
        }

        let newCursor = Self.encodeCursor(fileCursors)
        return (entries, newCursor)
    }

    // MARK: - Helpers

    /// Discover all `*.jsonl` transcripts under `projectsDir/*/`.
    private func transcriptFiles() -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsDir.path) else { return [] }
        var results: [URL] = []
        let projectDirs: [URL]
        do {
            projectDirs = try fm.contentsOfDirectory(
                at: projectsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }
        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: projectDir.path, isDirectory: &isDir) || !isDir.boolValue {
                continue
            }
            let files: [URL]
            do {
                files = try fm.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                continue
            }
            for f in files where f.pathExtension == "jsonl" {
                results.append(f)
            }
        }
        return results
    }

    /// JSON-encode `[path: ClaudeFileCursor]`. Empty / nil yields a fresh map.
    static func decodeCursor(_ data: Data?) -> [String: ClaudeFileCursor] {
        guard let data, !data.isEmpty else { return [:] }
        if let map = try? JSONDecoder().decode([String: ClaudeFileCursor].self, from: data) {
            // Detect the old `{offset: N}` shape mirrored from Python; clear it.
            // The Python adapter emits a stderr warning and starts over. We
            // mirror that behavior.
            return map
        }
        // Probe for the old bare-`offset` shape (`{"offset": N}`) — match
        // Python's warning + reset.
        if let any = try? JSONSerialization.jsonObject(with: data, options: []),
           let dict = any as? [String: Any], dict["offset"] != nil {
            AdapterHelpers.warn(
                "warning: old index format detected. Run 'recall --reindex' for best results."
            )
            return [:]
        }
        return [:]
    }

    static func encodeCursor(_ map: [String: ClaudeFileCursor]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(map)) ?? Data()
    }

    /// Strip Claude's internal tags (`<system-reminder>...`, etc.) and trim.
    static func stripTags(_ text: String) -> String {
        let stripped = Self.tagRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Naive decode of an encoded project dir back to an absolute path. Lossy
    /// — literal hyphens are indistinguishable from separators.
    static func decodeProjectDir(_ dirname: String) -> String {
        if dirname.hasPrefix("-") {
            let suffix = String(dirname.dropFirst())
            return "/" + suffix.replacingOccurrences(of: "-", with: "/")
        }
        return dirname.replacingOccurrences(of: "-", with: "/")
    }

    /// Extract text from a user message. Returns nil for tool-result arrays.
    static func extractUserText(message: [String: Any]) -> String? {
        let content = message["content"]
        if let string = content as? String { return string }
        // Array content = tool results — skip.
        return nil
    }

    /// Extract joined text blocks from an assistant message.
    static func extractAssistantText(message: [String: Any]) -> String? {
        guard let blocks = message["content"] as? [Any] else { return nil }
        var texts: [String] = []
        for block in blocks {
            guard let dict = block as? [String: Any] else { continue }
            if (dict["type"] as? String) == "text" {
                if let text = dict["text"] as? String, !text.isEmpty {
                    texts.append(text)
                }
            }
        }
        if texts.isEmpty { return nil }
        return texts.joined(separator: "\n")
    }

    // MARK: - Regex (compiled once)

    private static let stripTagNames: [String] = [
        "system-reminder",
        "local-command-stdout",
        "local-command-caveat",
        "command-name",
        "command-message",
        "command-args",
        "available-deferred-tools",
        "antml:thinking",
        "antml:thinking_mode",
        "antml:reasoning_effort",
    ]

    private static let tagRegex: NSRegularExpression = {
        let alternation = stripTagNames
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // Mirror Python: `<(?:tags)[^>]*>[\s\S]*?</(?:tags)>` with DOTALL.
        let pattern = "<(?:\(alternation))[^>]*>[\\s\\S]*?</(?:\(alternation))>"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    }()
}
