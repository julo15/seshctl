import Foundation

/// Identifies the LLM sessions Seshctl starts for its own purposes, so they
/// never become rows the user has to read past.
///
/// `SessionTitler` runs `claude -p --model haiku` to name a session. That
/// subprocess is an ordinary Claude Code run, so its `SessionStart` hook fires
/// and `seshctl-cli start` records it. Each titling run left about three rows,
/// all in the app's working directory (`/`), showing the generated title as
/// their preview text. In one real database 83 of 251 rows came from this.
///
/// Two defences, because they cover different rows:
///
/// - **Write-time.** `environmentMarker` is set on the subprocess. Claude Code
///   runs hooks as children of the CLI process, so the marker reaches every
///   hook event of that run, including subagents. `seshctl-cli` sees it and
///   records nothing.
/// - **Read-time.** `isSelfSpawned` recognises the rows already on disk from
///   before the write-time guard existed. They are hidden, not deleted, and age
///   out through the 30-day `gc`.
public enum InternalSession {

    /// Environment variable the app sets on LLM subprocesses it starts itself.
    /// Read by `seshctl-cli`, which then exits without touching the database.
    public static let environmentKey = "SESHCTL_INTERNAL_SESSION"

    /// The value to merge into a subprocess environment.
    public static let environmentMarker = [environmentKey: "1"]

    /// True when the current process descends from a Seshctl-spawned session.
    public static func isMarked(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }

    /// Bundle identifier of the app itself, as `Info.plist` declares it.
    ///
    /// A session whose *host app* is Seshctl was started by Seshctl: the
    /// terminal paths all go through `open -b` or AppleScript, which reparent
    /// the shell under the terminal app, so no user session can report this.
    public static let bundleIdentifier = "app.seshctl.Seshctl"

    /// True for a row Seshctl created for itself before the write-time guard
    /// landed. Only the host-app field is consulted; matching on the working
    /// directory would also catch a genuine session started in `/`.
    public static func isSelfSpawned(hostAppBundleId: String?) -> Bool {
        hostAppBundleId == bundleIdentifier
    }
}
