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
    id: Int64 = 0
) -> KeywordCandidate {
    KeywordCandidate(id: id, agent: agent, sessionID: session, timestamp: timestamp, rank: rank)
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

    @Test("An unclosed quote runs to the end of the input, its last word a prefix")
    func unclosedQuote() {
        #expect(KeywordQuery.matchExpression(for: #""stale rea"#) == #""stale rea"*"#)
        // A closed phrase stays exact.
        #expect(KeywordQuery.matchExpression(for: #""stale rea""#) == #""stale rea""#)
        // A one-letter last word isn't prefixed, like unquoted words.
        #expect(KeywordQuery.matchExpression(for: #"go "stale r"#) == #""go"* "stale r""#)
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
            hit(session: "A", rank: -2, timestamp: now, id: 1),
            hit(session: "A", rank: -9, timestamp: now, id: 2),
            hit(session: "B", rank: -5, timestamp: now),
        ]
        let ranked = KeywordRanking.rankSessions(hits, now: now, limit: 10)
        #expect(ranked.map(\.candidate.sessionID) == ["A", "B"])
        #expect(ranked.first?.candidate.id == 2)
    }

    @Test("Title matches rank above sessions that matched only in messages")
    func titleMatchesRankFirst() {
        let hits = [
            hit(session: "strong-message", rank: -50, timestamp: now),
            hit(session: "titled", rank: 0, timestamp: now - 90 * 86_400),
            hit(session: "titled-and-message", rank: -1, timestamp: now - 90 * 86_400),
        ]
        let ranked = KeywordRanking.rankSessions(
            hits, now: now, limit: 10,
            titleMatches: [
                KeywordRanking.sessionKey(agent: "claude", sessionID: "titled"),
                KeywordRanking.sessionKey(agent: "claude", sessionID: "titled-and-message"),
            ]
        )
        #expect(ranked.map(\.candidate.sessionID) == ["titled-and-message", "titled", "strong-message"])
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
        #expect(KeywordRanking.rankSessions(hits, now: now, limit: 10).map(\.candidate.sessionID) == ["new", "old"])
    }

    @Test("A much better old match still wins")
    func relevanceDominates() {
        let hits = [
            hit(session: "old", rank: -20, timestamp: now - 120 * 86_400),
            hit(session: "new", rank: -5, timestamp: now),
        ]
        #expect(KeywordRanking.rankSessions(hits, now: now, limit: 10).first?.candidate.sessionID == "old")
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
        #expect(ranked.map(\.candidate.sessionID) == ["newer", "older"])
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

    @Test("Concurrent first encodes share one build")
    func concurrentFirstEncodesShareBuild() async throws {
        let counter = Counter()
        let lazy = LazyEmbedder {
            await counter.bump()
            // Slow enough that the second encode arrives mid-build.
            try await Task.sleep(nanoseconds: 50_000_000)
            return MockEmbedder(perChunkDelayNanos: 0, vectorDim: 3)
        }
        async let first = lazy.encode(["a"], batchSize: 1, onProgress: nil)
        async let second = lazy.encode(["b"], batchSize: 1, onProgress: nil)
        let (a, b) = try await (first, second)
        #expect(a.count == 1 && b.count == 1)
        #expect(await counter.count == 1)
    }

    @Test("Concurrent encodes during a failing build all fail, and the next one retries")
    func concurrentFailingBuild() async throws {
        struct Boom: Error {}
        let counter = Counter()
        let lazy = LazyEmbedder {
            await counter.bump()
            try await Task.sleep(nanoseconds: 50_000_000)
            if await counter.count == 1 { throw Boom() }
            return MockEmbedder(perChunkDelayNanos: 0, vectorDim: 3)
        }
        async let first: [[Float]]? = try? lazy.encode(["a"], batchSize: 1, onProgress: nil)
        async let second: [[Float]]? = try? lazy.encode(["b"], batchSize: 1, onProgress: nil)
        let (a, b) = await (first, second)
        #expect(a == nil && b == nil)
        #expect(await counter.count == 1, "both waited on the same failed build")

        let vectors = try await lazy.encode(["c"], batchSize: 1, onProgress: nil)
        #expect(vectors.count == 1)
        #expect(await counter.count == 2)
    }
}
