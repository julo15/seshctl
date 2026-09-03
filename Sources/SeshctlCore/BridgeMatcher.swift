import Foundation

/// Identifies local Claude Code CLI sessions that are the same conversation
/// as a remote claude.ai Code-tab session.
///
/// The pairing is **deterministic**, not heuristic: Claude Code CLI writes an
/// explicit bridge event into its transcript when bridged, naming the
/// claude.ai `cse_<SUFFIX>` identifier the session belongs to (see
/// `TranscriptBridgeScanner` for the event shapes). `TranscriptBridgeScanner`
/// extracts that cse_id; this matcher pairs a local to the remote if
/// - the local is live (`idle`/`working`/`waiting`),
/// - the transcript declares a cse_id,
/// - that cse_id exists in the API response with `environment_kind == "bridge"`.
///
/// No timestamp windows, no repo/branch guessing — the transcript says
/// explicitly which bridge it belongs to.
public enum BridgeMatcher {

    /// Local statuses eligible for pairing. Completed/canceled/stale rows
    /// are historical — merging them with a live remote would confuse the
    /// user about what Enter will focus.
    static let eligibleLocalStatuses: Set<SessionStatus> = [.idle, .working, .waiting]

    /// Value of `environment_kind` that identifies a bridged remote. Native
    /// cloud sessions have a different value and can't have a CLI twin.
    static let bridgeEnvironmentKind: String = "bridge"

    /// A matched pair.
    public struct Pair: Equatable, Hashable, Sendable {
        public let localId: String
        public let remoteId: String

        public init(localId: String, remoteId: String) {
            self.localId = localId
            self.remoteId = remoteId
        }
    }

    /// Compute the set of bridged local/remote pairs.
    ///
    /// - Parameters:
    ///   - locals: All local sessions from the view model.
    ///   - remotes: All remote sessions from the view model.
    ///   - bridgedRemoteId: Closure returning the cse_id that a given local
    ///     transcript declares itself bridged to, or `nil` if the transcript
    ///     has never been bridged (or the file can't be read). Injected so
    ///     tests can hand in a pure mapping and prod can hit the filesystem
    ///     via `TranscriptBridgeScanner`.
    /// - Returns: The matched pairs. At most one pair per local and one per
    ///   remote. Policy when both sides have ambiguity:
    ///   - **First local wins**: if two locals declare the same cse_id
    ///     (e.g., two CLI processes resumed from the same session), the
    ///     first in iteration order gets the pair. Callers typically pass
    ///     `locals` sorted by `updated_at DESC`, so "most recently active"
    ///     wins — reasonable in practice.
    ///   - **Last scanner event wins**: the scanner returns only the most
    ///     recent bridge event per transcript. If a session rebridged
    ///     mid-run, the newer cse_id is the one used; any earlier cse_ids the
    ///     transcript referenced are ignored.
    public static func match(
        locals: [Session],
        remotes: [RemoteClaudeCodeSession],
        bridgedRemoteId: (Session) -> String?
    ) -> [Pair] {
        // Fast lookup: which remote IDs are live bridges right now?
        let liveBridgeIds: Set<String> = Set(
            remotes
                .filter { $0.environmentKind == bridgeEnvironmentKind }
                .map(\.id)
        )

        var pairedRemoteIds: Set<String> = []
        var pairs: [Pair] = []
        for local in locals where eligibleLocalStatuses.contains(local.status) {
            guard let cseId = bridgedRemoteId(local),
                  liveBridgeIds.contains(cseId),
                  !pairedRemoteIds.contains(cseId)
            else { continue }
            pairedRemoteIds.insert(cseId)
            pairs.append(Pair(localId: local.id, remoteId: cseId))
        }
        return pairs
    }
}
