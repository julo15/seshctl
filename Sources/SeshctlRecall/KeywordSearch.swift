// KeywordSearch — the pure half of the panel's history search: turning what
// the user typed into an FTS5 MATCH expression, and ranking message-level
// FTS matches into one row per session.
//
// Search runs in two steps. `VectorStore.keywordCandidates` ranks matching
// messages without reading their text, and `KeywordRanking` picks one per
// session. Then `VectorStore.keywordHits(match:ids:)` loads text and a
// snippet for just those rows. FTS5's `snippet()` re-tokenizes a message's
// whole text, so computing it for every match stalled on huge pasted
// messages (see `HistoryEntry.maxStoredTextLength`).
// `RecallStack.keywordSearch` wires the steps together. Nothing here touches
// the database.

import Foundation
import SeshctlCore

/// A message that matched a keyword query, without its text: what ranking
/// needs, and cheap to fetch for hundreds of matches.
public struct KeywordCandidate: Sendable, Equatable {
    /// `recall_entries` row id.
    public let id: Int64
    public let agent: String
    public let sessionID: String
    public let timestamp: Double
    /// FTS5 `bm25` score. More negative is a better match.
    public let rank: Double

    public init(id: Int64, agent: String, sessionID: String, timestamp: Double, rank: Double) {
        self.id = id
        self.agent = agent
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.rank = rank
    }
}

/// One message that matched a keyword query, with its text and snippet.
public struct KeywordHit: Sendable, Equatable {
    /// Marks the start of a matched term inside `snippet`. Shared with
    /// `RecallResult`, whose `snippetSegments` parses it for display.
    public static let matchStart = String(RecallResult.snippetMatchStart)
    /// Marks the end of a matched term inside `snippet`.
    public static let matchEnd = String(RecallResult.snippetMatchEnd)

    public let entry: HistoryEntry
    /// Excerpt around the match, with matched terms wrapped in
    /// `matchStart` / `matchEnd`.
    public let snippet: String

    public init(entry: HistoryEntry, snippet: String) {
        self.entry = entry
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
    ///   in order. An unclosed quote runs to the end of the input, and its
    ///   last word matches as a prefix (it's still being typed).
    /// - All words and phrases are required.
    /// - Input whose longest word is under two characters returns `nil`.
    ///
    /// Words only ever contain letters and digits, so the output can't
    /// contain FTS5 syntax the user didn't intend.
    public static func matchExpression(for query: String) -> String? {
        var terms: [String] = []
        var longestWord = 0

        let segments = query.split(separator: "\"", omittingEmptySubsequences: false)
        // An even segment count means an odd number of quotes: the last
        // phrase is still open.
        let lastPhraseIsOpen = segments.count % 2 == 0
        for (index, segment) in segments.enumerated() {
            let words = Self.words(in: segment)
            longestWord = max(longestWord, words.map(\.count).max() ?? 0)
            // Odd segments sit between quotes.
            if index % 2 == 1 {
                if !words.isEmpty {
                    let phrase = "\"\(words.joined(separator: " "))\""
                    let isOpen = lastPhraseIsOpen && index == segments.count - 1
                    // FTS5 applies a phrase's `*` to its last token.
                    terms.append(isOpen && (words.last?.count ?? 0) >= 2 ? phrase + "*" : phrase)
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
    /// Collapse message-level matches into one per session, best first.
    ///
    /// A session's representative hit is its best-ranked message. Its score
    /// is that message's relevance (`-bm25`) scaled by the age of the
    /// session's newest matching message: a match from today counts double
    /// one from months ago, and the bonus halves every three weeks. Ties go
    /// to the session with the newer match.
    ///
    /// - Parameters:
    ///   - candidates: message-level matches, in any order.
    ///   - now: unix seconds to measure age from.
    ///   - limit: cap on returned sessions.
    public static func rankSessions(
        _ candidates: [KeywordCandidate],
        now: Double,
        limit: Int
    ) -> [(candidate: KeywordCandidate, score: Double)] {
        guard limit > 0 else { return [] }

        var best: [String: KeywordCandidate] = [:]
        var latest: [String: Double] = [:]
        for candidate in candidates {
            let key = "\(candidate.agent)|\(candidate.sessionID)"
            if let current = best[key], current.rank <= candidate.rank {
                // keep current
            } else {
                best[key] = candidate
            }
            latest[key] = max(latest[key] ?? candidate.timestamp, candidate.timestamp)
        }

        let scored: [(candidate: KeywordCandidate, score: Double, latest: Double)] = best.map { key, candidate in
            let lastActive = latest[key] ?? candidate.timestamp
            return (candidate, score(rank: candidate.rank, lastActive: lastActive, now: now), lastActive)
        }

        return scored
            .sorted { a, b in
                a.score != b.score ? a.score > b.score : a.latest > b.latest
            }
            .prefix(limit)
            .map { ($0.candidate, $0.score) }
    }

    static let recencyHalfLifeDays = 21.0

    static func score(rank: Double, lastActive: Double, now: Double) -> Double {
        let ageDays = max(0, now - lastActive) / 86_400
        let recency = 0.5 + 0.5 * pow(0.5, ageDays / recencyHalfLifeDays)
        return -rank * recency
    }
}
