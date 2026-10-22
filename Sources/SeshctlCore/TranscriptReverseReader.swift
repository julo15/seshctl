import Foundation

/// Reads a JSONL transcript's lines newest-first, in chunks from the end of
/// the file, so "what is the latest X" scanners stop at the first decisive
/// line instead of decoding the whole file.
///
/// Transcripts run to 15 MB+ and the session list rescans changed ones on
/// the main thread every ~2s refresh; a forward pass that decodes every line
/// cost ~150 ms per scanner on such a file. Walking backwards, a scanner
/// typically touches only the last few KB.
public enum TranscriptReverseReader {

    /// What a per-line visitor wants next.
    public enum Step<Result> {
        /// This line decides the scan; stop with this value.
        case stop(Result)
        /// Not decisive; keep walking to older lines.
        case skip
    }

    /// Walk `transcriptPath`'s lines newest-first, calling `visit` on each
    /// non-empty line until it returns `.stop`. Returns that value, `nil` if
    /// every line was skipped, or `nil` if the file can't be opened.
    ///
    /// Reads `chunkSize`-byte blocks backwards. A line longer than one block
    /// grows the next read to the carried fragment's size, so a single huge
    /// line (a multi-MB tool result) costs linear, not quadratic, copying.
    public static func scan<Result>(
        transcriptPath: String,
        chunkSize: Int = 64 * 1024,
        visit: (Data) -> Step<Result>
    ) -> Result? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard var position = try? handle.seekToEnd() else { return nil }

        let newline = UInt8(ascii: "\n")
        // Bytes at the start of the previously read block that belong to a
        // line continuing into the (older) block not yet read.
        var carry = Data()
        while position > 0 {
            let readLength = UInt64(max(chunkSize, carry.count))
            let start = position > readLength ? position - readLength : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let block = try? handle.read(upToCount: Int(position - start))
            else { return nil }
            position = start

            var buffer = block
            buffer.append(carry)
            var end = buffer.endIndex
            while let lineBreak = buffer[buffer.startIndex..<end].lastIndex(of: newline) {
                let line = buffer[(lineBreak + 1)..<end]
                if !line.isEmpty, case .stop(let result) = visit(line) {
                    return result
                }
                end = lineBreak
            }
            carry = Data(buffer[buffer.startIndex..<end])
        }
        if !carry.isEmpty, case .stop(let result) = visit(carry) {
            return result
        }
        return nil
    }

    /// The same newest-first walk over an in-memory transcript. Used by the
    /// scanners' string-in entry points (tests), so both paths share one
    /// per-line decision function.
    public static func scan<Result>(
        transcript: String,
        visit: (Data) -> Step<Result>
    ) -> Result? {
        var lines: [String] = []
        transcript.enumerateLines { line, _ in lines.append(line) }
        for line in lines.reversed() where !line.isEmpty {
            if case .stop(let result) = visit(Data(line.utf8)) {
                return result
            }
        }
        return nil
    }
}
