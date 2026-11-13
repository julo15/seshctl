// KeywordSearchTests — the pure halves of history search: building an FTS5
// MATCH expression from user input, and ranking message hits into sessions.

import Foundation
import Testing

@testable import SeshctlCore
@testable import SeshctlRecall

private func hit(
    session: String,
    rank: Double,
    timestamp: Double,
    agent: String = "claude",
    text: String = "t"
) -> KeywordHit {
    KeywordHit(
        entry: HistoryEntry(
            id: nil,
            agent: agent,
            role: "user",
            sessionID: session,
            project: "/p",
            timestamp: timestamp,
            text: text,
            textHash: HistoryEntry.textHash(for: text)
        ),
        rank: rank,
        snippet: text
    )
}

@Suite("KeywordQuery")
struct KeywordQueryTests {
    @Test("Words become required prefix terms")
    func wordsArePrefixes() {
        #expect(KeywordQuery.matchExpression(for: "sparkle appc") == #""sparkle"* "appc"*"#)
    }

    @Test("Lowercases and splits on punctuation like the FTS tokenizer")
    func splitsOnPunctuation() {
        #expect(KeywordQuery.matchExpression(for: "Make-Appcast.sh") == #""make"* "appcast"* "sh"*"#)
    }

    @Test("One-character words match whole words only")
    func singleCharactersAreExact() {
        #expect(KeywordQuery.matchExpression(for: "fix a bug") == #""fix"* "a" "bug"*"#)
    }

    @Test("Quoted text is an exact phrase")
    func quotedPhrase() {
        #expect(KeywordQuery.matchExpression(for: #"zombie "stale reaper""#) == #""zombie"* "stale reaper""#)
    }

    @Test("An unclosed quote runs to the end of the input")
    func unclosedQuote() {
        #expect(KeywordQuery.matchExpression(for: #""stale rea"#) == #""stale rea""#)
    }

    @Test("FTS syntax in the input is neutralized")
    func neutralizesSyntax() {
        #expect(KeywordQuery.matchExpression(for: "foo* OR (bar) NEAR") == #""foo"* "or"* "bar"* "near"*"#)
    }

    @Test("Nothing searchable returns nil", arguments: ["", "   ", "a", "a b", "!!", #""""#])
    func nilWhenNothingSearchable(_ query: String) {
        #expect(KeywordQuery.matchExpression(for: query) == nil)
    }
}

@Suite("KeywordRanking")
struct KeywordRankingTests {
    let now = 1_800_000_000.0

    @Test("Collapses to one result per session, keeping its best message")
    func onePerSession() {
        let hits = [
            hit(session: "A", rank: -2, timestamp: now, text: "weak"),
            hit(session: "A", rank: -9, timestamp: now, text: "strong"),
            hit(session: "B", rank: -5, timestamp: now),
        ]
        let ranked = KeywordRanking.rankSessions(hits, now: now, limit: 10)
        #expect(ranked.map(\.hit.entry.sessionID) == ["A", "B"])
        #expect(ranked.first?.hit.entry.text == "strong")
    }

    @Test("Same session id under different agents stays separate")
    func agentIsPartOfKey() {
        let hits = [
            hit(session: "X", rank: -3, timestamp: now, agent: "claude"),
            hit(session: "X", rank: -3, timestamp: now, agent: "codex"),
        ]
        #expect(KeywordRanking.rankSessions(hits, now: now, limit: 10).count == 2)
    }

    @Test("Recency can outweigh a modestly better old match")
    func recencyBoost() {
        let hits = [
            hit(session: "old", rank: -6, timestamp: now - 120 * 86_400),
            hit(session: "new", rank: -5, timestamp: now),
        ]
        #expect(KeywordRanking.rankSessions(hits, now: now, limit: 10).map(\.hit.entry.sessionID) == ["new", "old"])
    }

    @Test("A much better old match still wins")
    func relevanceDominates() {
        let hits = [
            hit(session: "old", rank: -20, timestamp: now - 120 * 86_400),
            hit(session: "new", rank: -5, timestamp: now),
        ]
        #expect(KeywordRanking.rankSessions(hits, now: now, limit: 10).first?.hit.entry.sessionID == "old")
    }

    @Test("Equal scores go to the session with the newer match")
    func tieBreaksOnRecency() {
        // Ages so large the recency bonus is exactly zero, so both score
        // the same and only the timestamp decides.
        let ancient = now - 1e9 * 86_400
        let a = hit(session: "older", rank: -4, timestamp: ancient)
        let b = hit(session: "newer", rank: -4, timestamp: ancient + 1)
        #expect(
            KeywordRanking.score(rank: -4, lastActive: ancient, now: now)
                == KeywordRanking.score(rank: -4, lastActive: ancient + 1, now: now)
        )
        let ranked = KeywordRanking.rankSessions([a, b], now: now, limit: 10)
        #expect(ranked.map(\.hit.entry.sessionID) == ["newer", "older"])
    }

    @Test("Honors the limit")
    func limit() {
        let hits = (0..<5).map { hit(session: "S\($0)", rank: -Double($0 + 1), timestamp: now) }
        #expect(KeywordRanking.rankSessions(hits, now: now, limit: 2).count == 2)
        #expect(KeywordRanking.rankSessions(hits, now: now, limit: 0).isEmpty)
    }
}

@Suite("LazyEmbedder")
struct LazyEmbedderTests {
    actor Counter {
        var count = 0
        func bump() { count += 1 }
    }

    @Test("Builds the embedder once, on first encode")
    func buildsOnce() async throws {
        let counter = Counter()
        let lazy = LazyEmbedder {
            await counter.bump()
            return MockEmbedder(perChunkDelayNanos: 0, vectorDim: 3)
        }
        #expect(await counter.count == 0)
        _ = try await lazy.encode(["a"], batchSize: 1, onProgress: nil)
        let vectors = try await lazy.encode(["b", "c"], batchSize: 2, onProgress: nil)
        #expect(vectors.count == 2)
        #expect(await counter.count == 1)
    }

    @Test("Retries after a failed build")
    func retriesAfterFailure() async throws {
        struct Boom: Error {}
        let counter = Counter()
        let lazy = LazyEmbedder {
            await counter.bump()
            if await counter.count == 1 { throw Boom() }
            return MockEmbedder(perChunkDelayNanos: 0, vectorDim: 3)
        }
        await #expect(throws: Boom.self) {
            _ = try await lazy.encode(["a"], batchSize: 1, onProgress: nil)
        }
        let vectors = try await lazy.encode(["a"], batchSize: 1, onProgress: nil)
        #expect(vectors.count == 1)
        #expect(await counter.count == 2)
    }
}
