// KeywordSearch — the pure half of the panel's history search: turning what
// the user typed into an FTS5 MATCH expression, and ranking message-level
// FTS hits into one row per session.
//
// `VectorStore.keywordHits` runs the query; `RecallStack.keywordSearch`
// wires the two together. Nothing here touches the database.

import Foundation
import SeshctlCore

/// One message that matched a keyword query.
public struct KeywordHit: Sendable, Equatable {
    /// Marks the start of a matched term inside `snippet`. Shared with
    /// `RecallResult`, whose `snippetSegments` parses it for display.
    public static let matchStart = String(RecallResult.snippetMatchStart)
    /// Marks the end of a matched term inside `snippet`.
    public static let matchEnd = String(RecallResult.snippetMatchEnd)

    public let entry: HistoryEntry
    /// FTS5 `bm25` score. More negative is a better match.
    public let rank: Double
    /// Excerpt around the match, with matched terms wrapped in
    /// `matchStart` / `matchEnd`.
    public let snippet: String

    public init(entry: HistoryEntry, rank: Double, snippet: String) {
        self.entry = entry
        self.rank = rank
        self.snippet = snippet
    }
}

public enum KeywordQuery {
    /// Build an FTS5 MATCH expression from free-form user input, or `nil`
    /// when there's nothing worth searching.
    ///
    /// Rules:
    /// - Words split on anything that isn't a letter or digit, the same
    ///   boundaries FTS5's `unicode61` tokenizer uses. `make-appcast.sh`
    ///   searches for `make`, `appcast` and `sh`.
    /// - Every word of two or more characters matches as a prefix, so
    ///   `appc` finds `appcast` while typing. One-character words match
    ///   only as whole words, since a one-letter prefix matches nearly
    ///   every message and is slow.
    /// - Text in double quotes is a phrase: its words must appear together,
    ///   in order. An unclosed quote runs to the end of the input.
    /// - All words and phrases are required.
    /// - Input whose longest word is under two characters returns `nil`.
    ///
    /// Words only ever contain letters and digits, so the output can't
    /// contain FTS5 syntax the user didn't intend.
    public static func matchExpression(for query: String) -> String? {
        var terms: [String] = []
        var longestWord = 0

        let segments = query.split(separator: "\"", omittingEmptySubsequences: false)
        for (index, segment) in segments.enumerated() {
            let words = Self.words(in: segment)
            longestWord = max(longestWord, words.map(\.count).max() ?? 0)
            // Odd segments sit between quotes.
            if index % 2 == 1 {
                if !words.isEmpty {
                    terms.append("\"\(words.joined(separator: " "))\"")
                }
            } else {
                for word in words {
                    terms.append(word.count >= 2 ? "\"\(word)\"*" : "\"\(word)\"")
                }
            }
        }

        guard longestWord >= 2, !terms.isEmpty else { return nil }
        return terms.joined(separator: " ")
    }

    static func words(in text: Substring) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }
}

public enum KeywordRanking {
    /// Collapse message-level hits into one result per session, best first.
    ///
    /// A session's representative hit is its best-ranked message. Its score
    /// is that message's relevance (`-bm25`) scaled by the age of the
    /// session's newest matching message: a match from today counts double
    /// one from months ago, and the bonus halves every three weeks. Ties go
    /// to the session with the newer match.
    ///
    /// - Parameters:
    ///   - hits: message-level hits, in any order.
    ///   - now: unix seconds to measure age from.
    ///   - limit: cap on returned sessions.
    public static func rankSessions(
        _ hits: [KeywordHit],
        now: Double,
        limit: Int
    ) -> [(hit: KeywordHit, score: Double)] {
        guard limit > 0 else { return [] }

        var best: [String: KeywordHit] = [:]
        var latest: [String: Double] = [:]
        for hit in hits {
            let key = "\(hit.entry.agent)|\(hit.entry.sessionID)"
            if let current = best[key], current.rank <= hit.rank {
                // keep current
            } else {
                best[key] = hit
            }
            latest[key] = max(latest[key] ?? hit.entry.timestamp, hit.entry.timestamp)
        }

        let scored: [(hit: KeywordHit, score: Double, latest: Double)] = best.map { key, hit in
            let lastActive = latest[key] ?? hit.entry.timestamp
            return (hit, score(rank: hit.rank, lastActive: lastActive, now: now), lastActive)
        }

        return scored
            .sorted { a, b in
                a.score != b.score ? a.score > b.score : a.latest > b.latest
            }
            .prefix(limit)
            .map { ($0.hit, $0.score) }
    }

    static let recencyHalfLifeDays = 21.0

    static func score(rank: Double, lastActive: Double, now: Double) -> Double {
        let ageDays = max(0, now - lastActive) / 86_400
        let recency = 0.5 + 0.5 * pow(0.5, ageDays / recencyHalfLifeDays)
        return -rank * recency
    }
}
