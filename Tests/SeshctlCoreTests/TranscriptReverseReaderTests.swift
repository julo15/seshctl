import Foundation
import Testing

@testable import SeshctlCore

@Suite("TranscriptReverseReader")
struct TranscriptReverseReaderTests {

    private func write(_ text: String) throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Every non-empty line, newest-first, as the reader yields them.
    private func allLines(_ path: String, chunkSize: Int) -> [String] {
        var seen: [String] = []
        let _: Int? = TranscriptReverseReader.scan(transcriptPath: path, chunkSize: chunkSize) { line in
            seen.append(String(decoding: line, as: UTF8.self))
            return .skip
        }
        return seen
    }

    @Test("yields lines newest-first across chunk boundaries", arguments: [1, 3, 7, 64, 64 * 1024])
    func newestFirstAcrossChunks(chunkSize: Int) throws {
        let lines = ["first line", "second", "", "third — ünïcödé", "4"]
        let path = try write(lines.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(allLines(path, chunkSize: chunkSize) == ["4", "third — ünïcödé", "second", "first line"])
    }

    @Test("a final line without a newline is still yielded first")
    func noTrailingNewline() throws {
        let path = try write("a\nb\nlast")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(allLines(path, chunkSize: 2) == ["last", "b", "a"])
    }

    @Test("a line far longer than the chunk size comes through intact")
    func hugeLine() throws {
        let huge = String(repeating: "x", count: 50_000)
        let path = try write("start\n\(huge)\nend\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(allLines(path, chunkSize: 16) == ["end", huge, "start"])
    }

    @Test("stops at the first .stop and returns its value")
    func stopsEarly() throws {
        let path = try write("one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        var visited = 0
        let result: String? = TranscriptReverseReader.scan(transcriptPath: path, chunkSize: 4) { line in
            visited += 1
            let text = String(decoding: line, as: UTF8.self)
            return text == "two" ? .stop(text) : .skip
        }
        #expect(result == "two")
        #expect(visited == 2)
    }

    @Test("empty and missing files yield nothing")
    func emptyAndMissing() throws {
        let path = try write("")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(allLines(path, chunkSize: 8).isEmpty)
        let missing: Int? = TranscriptReverseReader.scan(transcriptPath: "/tmp/does-not-exist-\(UUID().uuidString)") { _ in .stop(1) }
        #expect(missing == nil)
    }

    @Test("in-memory scan matches the file scan")
    func stringMatchesFile() throws {
        let text = "a\nb\n\nc\n"
        var fromString: [String] = []
        let _: Int? = TranscriptReverseReader.scan(transcript: text) { line in
            fromString.append(String(decoding: line, as: UTF8.self))
            return .skip
        }
        let path = try write(text)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(fromString == allLines(path, chunkSize: 3))
    }
}
