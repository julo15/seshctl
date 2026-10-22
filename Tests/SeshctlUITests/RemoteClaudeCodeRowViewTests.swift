import Foundation
import SwiftUI
import Testing

@testable import SeshctlCore
@testable import SeshctlUI

// MARK: - StatusKind.forRemote tests

@Suite("StatusKind.forRemote")
struct StatusKindForRemoteTests {

    @Test("stale wins when auth-expired, regardless of worker state")
    func staleBeatsEverything() {
        let s = StatusKind.forRemote(
            workerStatus: "running",
            connectionStatus: "connected",
            isStale: true
        )
        #expect(s == .stale)
    }

    @Test("running worker is .working (shared vocabulary)")
    func runningWorker() {
        let s = StatusKind.forRemote(
            workerStatus: "running",
            connectionStatus: "connected",
            isStale: false
        )
        #expect(s == .working)
    }

    @Test("waiting worker is .waiting")
    func waitingWorker() {
        let s = StatusKind.forRemote(
            workerStatus: "waiting",
            connectionStatus: "connected",
            isStale: false
        )
        #expect(s == .waiting)
    }

    @Test("requires_action worker is .waiting (pending user input)")
    func requiresActionWorker() {
        let s = StatusKind.forRemote(
            workerStatus: "requires_action",
            connectionStatus: "connected",
            isStale: false
        )
        #expect(s == .waiting)
    }

    @Test("idle + connected is .idle")
    func idleConnected() {
        let s = StatusKind.forRemote(
            workerStatus: "idle",
            connectionStatus: "connected",
            isStale: false
        )
        #expect(s == .idle)
    }

    @Test("disconnected connection is .offline")
    func disconnectedConnection() {
        let s = StatusKind.forRemote(
            workerStatus: "idle",
            connectionStatus: "disconnected",
            isStale: false
        )
        #expect(s == .offline)
    }

    @Test("disconnected worker is .offline")
    func disconnectedWorker() {
        let s = StatusKind.forRemote(
            workerStatus: "disconnected",
            connectionStatus: "connected",
            isStale: false
        )
        #expect(s == .offline)
    }

    @Test("stale beats waiting")
    func staleBeatsWaiting() {
        let s = StatusKind.forRemote(
            workerStatus: "waiting",
            connectionStatus: "connected",
            isStale: true
        )
        #expect(s == .stale)
    }

    @Test("unknown worker_status with connected falls through to .idle")
    func unknownWorkerFallsThroughToIdle() {
        let s = StatusKind.forRemote(
            workerStatus: "some_future_state",
            connectionStatus: "connected",
            isStale: false
        )
        #expect(s == .idle)
    }
}

// MARK: - StatusKind color tests

@Suite("StatusKind.color")
struct StatusKindColorTests {

    @Test("waiting is orange")
    func waitingIsOrange() {
        #expect(StatusKind.waiting.color == .orange)
    }

    @Test("working is green")
    func workingIsGreen() {
        #expect(StatusKind.working.color == .green)
    }

    @Test("idle is gray")
    func idleIsGray() {
        #expect(StatusKind.idle.color == .gray)
    }

    @Test("offline is gray")
    func offlineIsGray() {
        #expect(StatusKind.offline.color == .gray)
    }

    @Test("completed is gray (same visual as offline, distinct semantics)")
    func completedIsGray() {
        #expect(StatusKind.completed.color == .gray)
    }

    @Test("canceled is red")
    func canceledIsRed() {
        #expect(StatusKind.canceled.color == .red)
    }

    @Test("only ended sessions render hollow")
    func onlyEndedSessionsAreHollow() {
        #expect(StatusKind.completed.isHollow)
        #expect(StatusKind.offline.isHollow)
        for kind in [StatusKind.working, .waiting, .idle, .canceled, .stale] {
            #expect(!kind.isHollow)
        }
    }
}

// MARK: - StatusKind animation flags

@Suite("StatusKind animation flags")
struct StatusKindAnimationFlagsTests {

    @Test("only .working pulses")
    func onlyWorkingPulses() {
        #expect(StatusKind.working.isPulsing)
        #expect(!StatusKind.waiting.isPulsing)
        #expect(!StatusKind.idle.isPulsing)
        #expect(!StatusKind.offline.isPulsing)
        #expect(!StatusKind.stale.isPulsing)
    }

    @Test("only .waiting blinks")
    func onlyWaitingBlinks() {
        #expect(StatusKind.waiting.isBlinking)
        #expect(!StatusKind.working.isBlinking)
        #expect(!StatusKind.idle.isBlinking)
        #expect(!StatusKind.offline.isBlinking)
    }
}

// MARK: - SessionStatus → StatusKind mapping

@Suite("SessionStatus.statusKind")
struct SessionStatusStatusKindTests {
    @Test func working() { #expect(SessionStatus.working.statusKind == .working) }
    @Test func waiting() { #expect(SessionStatus.waiting.statusKind == .waiting) }
    @Test func idle() { #expect(SessionStatus.idle.statusKind == .idle) }
    @Test func completed() { #expect(SessionStatus.completed.statusKind == .completed) }
    @Test func canceled() { #expect(SessionStatus.canceled.statusKind == .canceled) }
    @Test func stale() { #expect(SessionStatus.stale.statusKind == .stale) }
}
