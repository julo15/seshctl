import Foundation

/// Timeout-bounded subprocess runner. Returns nil only on launch failure or
/// timeout; on any subprocess exit (zero or non-zero), returns a tuple with
/// stdout, stderr, and the exit status. Callers decide how to react to non-zero
/// status — `RealSystemEnvironment.runShellCommandCapturingStdout` treats it as
/// failure (returns nil) for back-compat; `ExtensionInstaller` (in Step 2) will
/// inspect status and stderr for error reporting.
public enum ShellRunner {
    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let status: Int32
        public init(stdout: String, stderr: String, status: Int32) {
            self.stdout = stdout
            self.stderr = stderr
            self.status = status
        }
    }

    /// Runs `path` with `args` and captures both stdout and stderr. The process
    /// is terminated after `timeout` seconds; SIGTERM is given 0.5s to flush
    /// before we give up. Returns nil if the executable couldn't launch or the
    /// timeout fired (partial output is discarded in both cases).
    ///
    /// `extraEnvironment` is merged *onto* the inherited environment rather
    /// than replacing it. Assigning `process.environment` outright would strip
    /// `PATH` and `HOME` from the child, which breaks every CLI we launch.
    public static func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        extraEnvironment: [String: String]? = nil
    ) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let extraEnvironment {
            process.environment = ProcessInfo.processInfo.environment
                .merging(extraEnvironment) { _, added in added }
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            // Daemon wedged or process otherwise unresponsive — terminate and
            // give SIGTERM a brief grace period so the handler signals before
            // we return. Any partial output buffered in the pipes is discarded.
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.5)
            return nil
        }

        // Pipes closed when child exited; readDataToEndOfFile returns immediately.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = (String(data: stdoutData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = (String(data: stderrData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }
}
