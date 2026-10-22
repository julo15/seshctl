import Foundation
import Testing

@testable import SeshctlCore

@Suite("TranscriptTitleScanner")
struct TranscriptTitleScannerTests {

    @Test("empty transcript returns nil")
    func empty() {
        #expect(TranscriptTitleScanner.extractTitle(transcript: "") == nil)
    }

    @Test("transcript with no title records returns nil")
    func noTitleRecords() {
        let transcript = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"role":"assistant","content":"hello"}}
        """
        #expect(TranscriptTitleScanner.extractTitle(transcript: transcript) == nil)
    }

    @Test("ai-title record returns its value")
    func aiTitle() {
        let transcript = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"ai-title","aiTitle":"Xcode build error","sessionId":"abc"}
        """
        #expect(TranscriptTitleScanner.extractTitle(transcript: transcript) == "Xcode build error")
    }

    @Test("last ai-title wins")
    func lastAiTitleWins() {
        let transcript = """
        {"type":"ai-title","aiTitle":"First title"}
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"ai-title","aiTitle":"Second title"}
        """
        #expect(TranscriptTitleScanner.extractTitle(transcript: transcript) == "Second title")
    }

    @Test("custom-title is the fallback when there is no ai-title")
    func customTitleFallback() {
        let transcript = """
        {"type":"custom-title","customTitle":"m5: qbk"}
        {"type":"agent-name","agentName":"m5: qbk"}
        """
        #expect(TranscriptTitleScanner.extractTitle(transcript: transcript) == "m5: qbk")
    }

    @Test("ai-title wins over custom-title regardless of order")
    func aiTitleBeatsCustomTitle() {
        let transcript = """
        {"type":"ai-title","aiTitle":"Dating apps for social groups"}
        {"type":"custom-title","customTitle":"m5: next"}
        """
        #expect(TranscriptTitleScanner.extractTitle(transcript: transcript) == "Dating apps for social groups")
    }

    @Test("whitespace-only titles are ignored and values are trimmed")
    func whitespaceHandling() {
        let transcript = """
        {"type":"custom-title","customTitle":"  Renamed  "}
        {"type":"ai-title","aiTitle":"   "}
        """
        #expect(TranscriptTitleScanner.extractTitle(transcript: transcript) == "Renamed")
    }

    @Test("title text mentioning another record type doesn't confuse the pre-filter")
    func malformedAndNoiseLines() {
        let transcript = """
        not json "ai-title"
        {"type":"user","message":{"role":"user","content":"what is \\"ai-title\\"?"}}
        {"type":"ai-title","aiTitle":"Real title"}
        """
        #expect(TranscriptTitleScanner.extractTitle(transcript: transcript) == "Real title")
    }

    @Test("reads a real temp file on disk")
    func readsFileFromDisk() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
        try #"{"type":"ai-title","aiTitle":"Title from disk"}"#.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(TranscriptTitleScanner.extractTitle(transcriptPath: path) == "Title from disk")
    }

    @Test("missing file returns nil (doesn't throw)")
    func missingFile() {
        #expect(TranscriptTitleScanner.extractTitle(transcriptPath: "/tmp/does-not-exist-\(UUID().uuidString).jsonl") == nil)
    }

    // MARK: - Incremental scanning

    private func tempPath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
    }

    private func append(_ text: String, to path: String) throws {
        let handle = try #require(FileHandle(forWritingAtPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test("resumed scan picks up only appended records and advances the offset")
    func resumesFromOffset() throws {
        let path = tempPath()
        let first = #"{"type":"user"}"# + "\n" + #"{"type":"custom-title","customTitle":"m5: qbk"}"# + "\n"
        try first.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let s1 = try #require(TranscriptTitleScanner.scan(transcriptPath: path, resuming: nil))
        #expect(s1.title == "m5: qbk")
        #expect(s1.offset == UInt64(first.utf8.count))

        try append(#"{"type":"ai-title","aiTitle":"Booking flow"}"# + "\n", to: path)
        let s2 = try #require(TranscriptTitleScanner.scan(transcriptPath: path, resuming: s1))
        #expect(s2.title == "Booking flow")
        #expect(s2.customTitle == "m5: qbk")
    }

    @Test("resumed scan keeps prior titles when nothing new was appended")
    func unchangedFileKeepsState() throws {
        let path = tempPath()
        try (#"{"type":"ai-title","aiTitle":"Stable"}"# + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let s1 = try #require(TranscriptTitleScanner.scan(transcriptPath: path, resuming: nil))
        let s2 = try #require(TranscriptTitleScanner.scan(transcriptPath: path, resuming: s1))
        #expect(s2 == s1)
    }

    @Test("a partial trailing line is left for the next scan")
    func partialLineDeferred() throws {
        let path = tempPath()
        let complete = #"{"type":"user"}"# + "\n"
        try (complete + #"{"type":"ai-title","aiTi"#).write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let s1 = try #require(TranscriptTitleScanner.scan(transcriptPath: path, resuming: nil))
        #expect(s1.title == nil)
        #expect(s1.offset == UInt64(complete.utf8.count))

        try append(#"tle":"Finished line"}"# + "\n", to: path)
        let s2 = try #require(TranscriptTitleScanner.scan(transcriptPath: path, resuming: s1))
        #expect(s2.title == "Finished line")
    }

    @Test("a file shorter than the saved offset is rescanned from scratch")
    func truncatedFileRescans() throws {
        let path = tempPath()
        try (#"{"type":"ai-title","aiTitle":"Old title, long line padding"}"# + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s1 = try #require(TranscriptTitleScanner.scan(transcriptPath: path, resuming: nil))

        try (#"{"type":"ai-title","aiTitle":"New"}"# + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let s2 = try #require(TranscriptTitleScanner.scan(transcriptPath: path, resuming: s1))
        #expect(s2.title == "New")
    }

    @Test("multiple title records on adjacent lines are all applied in order")
    func adjacentRecords() {
        let transcript = """
        {"type":"ai-title","aiTitle":"One"}
        {"type":"ai-title","aiTitle":"Two"}
        {"type":"custom-title","customTitle":"Three"}
        """
        #expect(TranscriptTitleScanner.extractTitle(transcript: transcript) == "Two")
    }
}
