import Darwin

/// Whether a session's recorded PID still names a running process.
public enum ProcessLiveness {
    /// True when `pid` exists and isn't a zombie.
    ///
    /// `kill(pid, 0)` alone reports zombies as alive: the PID stays in the
    /// process table until the parent reaps it, and a parent that never does
    /// keeps it there indefinitely. Codex's app-server daemon leaves exactly
    /// these behind, so its dead sessions were never reaped and `x` sent
    /// SIGTERM to a process that can't receive it. The zombie state comes
    /// from `sysctl`, because `proc_pidinfo` fails outright for zombies.
    public static func isAlive(_ pid: Int) -> Bool {
        guard kill(pid_t(pid), 0) == 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            // kill() just saw it, so a failed lookup means it exited in between.
            return false
        }
        return info.kp_proc.p_stat != SZOMB
    }
}
