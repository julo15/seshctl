import Darwin
import Foundation
import Testing
@testable import SeshctlCore

@Suite("ProcessLiveness")
struct ProcessLivenessTests {
    @Test("Current process is alive")
    func selfIsAlive() {
        #expect(ProcessLiveness.isAlive(Int(getpid())))
    }

    /// The bug this guards: `kill(pid, 0)` returns 0 for a zombie, so dead
    /// Codex sessions whose recorded PID was never reaped stayed active.
    @Test("An exited child that hasn't been reaped (zombie) is not alive")
    func zombieIsNotAlive() throws {
        let pid = try spawnTrue()
        defer { var status: Int32 = 0; waitpid(pid, &status, 0) }

        try waitUntilZombie(pid)
        #expect(kill(pid, 0) == 0, "precondition: kill(pid, 0) still reports the zombie")
        #expect(!ProcessLiveness.isAlive(Int(pid)))
    }

    @Test("A reaped child is not alive")
    func reapedIsNotAlive() throws {
        let pid = try spawnTrue()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(!ProcessLiveness.isAlive(Int(pid)))
    }

    private func spawnTrue() throws -> pid_t {
        var pid: pid_t = 0
        let path = "/usr/bin/true"
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, path, nil, nil, &argv, environ)
        try #require(rc == 0, "posix_spawn failed: \(rc)")
        return pid
    }

    private func waitUntilZombie(_ pid: pid_t) throws {
        for _ in 0..<200 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            if sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
               size > 0, info.kp_proc.p_stat == SZOMB {
                return
            }
            usleep(10_000)
        }
        Issue.record("child \(pid) never became a zombie")
    }
}
