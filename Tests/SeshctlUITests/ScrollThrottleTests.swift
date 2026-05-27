import Foundation
import Testing

@testable import SeshctlUI

@Suite("ScrollThrottle")
struct ScrollThrottleTests {
    @Test("first call is always allowed")
    func firstCallAllowed() {
        var t = ScrollThrottle(minInterval: 0.05)
        let allowed = t.allow(now: 100.0)
        #expect(allowed)
    }

    @Test("call inside the window is dropped")
    func droppedInsideWindow() {
        var t = ScrollThrottle(minInterval: 0.05)
        _ = t.allow(now: 100.0)
        let earlyA = t.allow(now: 100.02)
        let earlyB = t.allow(now: 100.049)
        #expect(!earlyA)
        #expect(!earlyB)
    }

    @Test("boundary uses strict less-than (a call exactly at minInterval is allowed)")
    func boundaryStrictLessThan() {
        // Use a binary-representable interval (0.5) so the boundary check
        // doesn't get muddled by floating-point rounding the way 0.05 does.
        var t = ScrollThrottle(minInterval: 0.5)
        _ = t.allow(now: 100.0)
        let justBefore = t.allow(now: 100.4999)
        let atBoundary = t.allow(now: 100.5)
        #expect(!justBefore)
        #expect(atBoundary)
    }

    @Test("call past the window is accepted and re-stamps")
    func acceptedPastWindow() {
        var t = ScrollThrottle(minInterval: 0.05)
        _ = t.allow(now: 100.0)
        let pastOnce = t.allow(now: 100.06)
        let immediatelyAfter = t.allow(now: 100.07)
        let pastTwice = t.allow(now: 100.12)
        #expect(pastOnce)
        #expect(!immediatelyAfter)
        #expect(pastTwice)
    }

    @Test("dropped calls do NOT update lastFiredAt")
    func droppedDoesNotStamp() {
        var t = ScrollThrottle(minInterval: 0.05)
        _ = t.allow(now: 100.0)
        _ = t.allow(now: 100.02)
        _ = t.allow(now: 100.04)
        #expect(t.lastFiredAt == 100.0)
        let accepted = t.allow(now: 100.06)
        #expect(accepted)
        #expect(t.lastFiredAt == 100.06)
    }
}
