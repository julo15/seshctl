import Foundation
import Testing

@testable import SeshctlCore

@Suite("InternalSession")
struct InternalSessionTests {

    // MARK: - Write-time marker

    @Test("The marker is recognised in an environment that carries it")
    func markerRecognised() {
        #expect(InternalSession.isMarked(environment: InternalSession.environmentMarker))
    }

    @Test("An ordinary environment is not marked")
    func plainEnvironmentUnmarked() {
        #expect(!InternalSession.isMarked(environment: [:]))
        #expect(!InternalSession.isMarked(environment: ["PATH": "/usr/bin"]))
    }

    @Test("Only the exact value counts as marked")
    func partialValueUnmarked() {
        // A stale or hand-set variable must not silence session recording.
        #expect(!InternalSession.isMarked(environment: [InternalSession.environmentKey: "0"]))
        #expect(!InternalSession.isMarked(environment: [InternalSession.environmentKey: ""]))
    }

    // MARK: - Read-time filter

    @Test("A row hosted by Seshctl is self-spawned")
    func seshctlHostIsSelfSpawned() {
        #expect(InternalSession.isSelfSpawned(hostAppBundleId: "app.seshctl.Seshctl"))
        #expect(InternalSession.isSelfSpawned(hostAppBundleId: InternalSession.bundleIdentifier))
    }

    @Test("Terminal-hosted and host-less rows are left alone")
    func realRowsSurvive() {
        // Ghostty is the common host; nil covers the rows where the PID walk
        // found no GUI app at all.
        #expect(!InternalSession.isSelfSpawned(hostAppBundleId: "com.mitchellh.ghostty"))
        #expect(!InternalSession.isSelfSpawned(hostAppBundleId: nil))
        #expect(!InternalSession.isSelfSpawned(hostAppBundleId: "com.microsoft.VSCode"))
    }
}
