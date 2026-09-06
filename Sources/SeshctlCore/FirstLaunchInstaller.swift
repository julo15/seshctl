import Foundation

// MARK: - FirstLaunchInstaller

/// First-launch / on-demand installer for seshctl. Used by both the GUI app
/// (from `AppDelegate.applicationDidFinishLaunching` when the marker file is
/// missing) and the CLI (`seshctl-cli install`).
///
/// All operations are idempotent — running install twice is safe, running
/// uninstall against partial state is safe.
public enum FirstLaunchInstaller {

    // MARK: Result + error types

    public enum Action: Equatable {
        case symlinkCreated(String, target: String)
        case symlinkReplaced(String, target: String)
        case migratedRealFileToSymlink(String)
        case uninstallerScriptWritten(String)
        case hookScriptWritten(String)
        case hookRegistered(llm: String, event: String)
        case hookAlreadyRegistered(llm: String, event: String)
        case codexConfigUpdated
        case codexConfigAlreadySet
        case codexConfigCleared(String)
        case markerFileWritten(String)
        case removedHookEntry(llm: String, event: String)
        case removedSymlink(String)
        case removedFile(String)
        case removedDirectory(String)
        case noted(String)
    }

    public struct InstallResult {
        public let actions: [Action]
        public init(actions: [Action]) { self.actions = actions }
    }

    /// Decoded contents of the marker file written by `writeMarkerFile`.
    /// Matches the JSON keys produced there byte-for-byte
    /// (`bundlePath` / `version` / `installedAt`), so existing markers in the
    /// wild remain readable.
    ///
    /// `installedAt` is stored on disk as a `Double` (seconds since 1970),
    /// preserving sub-second precision so the `reconcileInstall` mtime
    /// comparison doesn't fire spuriously on every launch. For back-compat,
    /// `currentMarkerState(paths:)` also accepts a legacy ISO 8601 string
    /// representation (used by markers written before this change).
    public struct MarkerState: Equatable, Sendable {
        public let bundlePath: String
        public let version: String
        public let installedAt: Date

        public init(bundlePath: String, version: String, installedAt: Date) {
            self.bundlePath = bundlePath
            self.version = version
            self.installedAt = installedAt
        }
    }

    /// Result of `reconcileInstall(...)`: a pure description of what the
    /// caller should do based on the marker file vs the current bundle.
    /// Side effects (showing a welcome panel, calling `install`, logging)
    /// live in `AppDelegate`, which switches on this value.
    public enum InstallReconciliation: Equatable, Sendable {
        /// Not running from a .app bundle (dev / swift run). Skip install.
        case notRunningFromBundle

        /// Marker file missing — first launch. Caller shows welcome panel.
        case needsFreshInstall

        /// Marker exists and matches current bundle. No action needed.
        case noChange

        /// Marker exists but is stale relative to current bundle. Caller
        /// should silently call `install(bundleURL:)` and log the result.
        case needsRefresh(reason: RefreshReason)
    }

    /// Why `reconcileInstall` chose `.needsRefresh`. Exposed so the caller
    /// can write a human-readable line to the install log.
    public enum RefreshReason: Equatable, Sendable, CustomStringConvertible {
        case bundlePathChanged(from: String, to: String)
        case versionChanged(from: String, to: String)
        case bundleNewer(installedAt: Date, executableMtime: Date)

        public var description: String {
            switch self {
            case .bundlePathChanged(let from, let to):
                return "bundle path moved from \(from) to \(to)"
            case .versionChanged(let from, let to):
                return "version changed from \(from) to \(to)"
            case .bundleNewer(let installedAt, let mtime):
                return "bundle executable mtime \(mtime) > marker installedAt \(installedAt)"
            }
        }
    }

    public struct UninstallResult {
        public let actions: [Action]
        public init(actions: [Action]) { self.actions = actions }
    }

    public enum InstallError: Error, CustomStringConvertible, LocalizedError {
        case cliBinaryNotFound(searched: [String])
        case hookSourceNotFound(searched: [String])
        case ioError(String, underlying: Error)
        case malformedSettings(path: String, backupPath: String)

        public var description: String {
            switch self {
            case .cliBinaryNotFound(let searched):
                return "Could not locate the seshctl-cli binary. Searched: \(searched.joined(separator: ", "))"
            case .hookSourceNotFound(let searched):
                return "Could not locate hook source scripts. Searched: \(searched.joined(separator: ", "))"
            case .ioError(let msg, let underlying):
                return "I/O error: \(msg) — \(underlying)"
            case .malformedSettings(let path, let backupPath):
                return "Refusing to overwrite malformed JSON at \(path). The original file has been backed up to \(backupPath). Fix or remove the file and re-run install."
            }
        }

        /// Surfaces `description` through Foundation's `localizedDescription`
        /// so the GUI error alert (which uses `error.localizedDescription`)
        /// renders the same human-readable message as the CLI.
        public var errorDescription: String? { description }
    }

    // MARK: Public API

    /// True if the marker file exists at
    /// `~/Library/Application Support/Seshctl/installed-v1.json`.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: defaultPaths.markerFile)
    }

    /// Default `Paths` instance rooted at the current user's home directory.
    /// Production code uses this; tests inject a temp-rooted `Paths` instead.
    public static let defaultPaths = Paths()

    /// Reads the marker file at `paths.markerFile` and returns its contents as
    /// a `MarkerState`. Returns `nil` if the file is missing or malformed.
    /// Does not throw — a missing/corrupt marker is just "no install record."
    public static func currentMarkerState(paths: Paths = Paths()) -> MarkerState? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.markerFile) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.markerFile)),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let bundlePath = dict["bundlePath"] as? String,
              let version = dict["version"] as? String
        else {
            return nil
        }

        // `installedAt` is currently written as a `Double` (seconds since
        // 1970) to preserve sub-second precision. Legacy markers (written
        // before that change) stored it as an ISO 8601 string; accept both
        // shapes so old markers on user machines keep parsing.
        let installedAt: Date
        if let secs = dict["installedAt"] as? Double {
            installedAt = Date(timeIntervalSince1970: secs)
        } else if let installedAtStr = dict["installedAt"] as? String,
                  let parsed = ISO8601DateFormatter().date(from: installedAtStr) {
            installedAt = parsed
        } else {
            return nil
        }

        return MarkerState(
            bundlePath: bundlePath, version: version, installedAt: installedAt
        )
    }

    /// Pure decision function for the per-launch install reconcile. Reads
    /// the marker file at `paths.markerFile` and compares it against the
    /// running bundle to decide what `AppDelegate` should do.
    ///
    /// Mapping of inputs → result:
    ///   - `bundleURL == nil` or its `pathExtension != "app"`:
    ///     `.notRunningFromBundle` (skip install entirely; we're in
    ///     `swift run SeshctlApp` / dev mode).
    ///   - Marker absent: `.needsFreshInstall` (caller shows welcome panel).
    ///   - Marker present, `bundlePath` differs from `bundleURL.path`:
    ///     `.needsRefresh(reason: .bundlePathChanged(...))` (bundle moved).
    ///   - Marker present, `version` differs from `currentVersion`:
    ///     `.needsRefresh(reason: .versionChanged(...))` (release bump).
    ///   - Marker present, bundle's `Contents/MacOS/SeshctlApp` mtime is
    ///     newer than `installedAt`:
    ///     `.needsRefresh(reason: .bundleNewer(...))` (dev `cp -R` where
    ///     the version string didn't change).
    ///   - Otherwise: `.noChange`.
    ///
    /// Performs no side effects — read-only against the filesystem.
    public static func reconcileInstall(
        bundleURL: URL?,
        currentVersion: String,
        paths: Paths = Paths()
    ) -> InstallReconciliation {
        guard let bundleURL, bundleURL.pathExtension == "app" else {
            return .notRunningFromBundle
        }
        guard let marker = currentMarkerState(paths: paths) else {
            return .needsFreshInstall
        }
        if marker.bundlePath != bundleURL.path {
            return .needsRefresh(reason: .bundlePathChanged(from: marker.bundlePath, to: bundleURL.path))
        }
        if marker.version != currentVersion {
            return .needsRefresh(reason: .versionChanged(from: marker.version, to: currentVersion))
        }
        let exeURL = bundleURL.appendingPathComponent("Contents/MacOS/SeshctlApp")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: exeURL.path),
           let mtime = attrs[.modificationDate] as? Date,
           mtime > marker.installedAt {
            return .needsRefresh(reason: .bundleNewer(installedAt: marker.installedAt, executableMtime: mtime))
        }
        return .noChange
    }

    /// Full install: hooks + symlinks + uninstaller script + marker file.
    ///
    /// `bundleURL` is the .app bundle URL (e.g. `Bundle.main.bundleURL` when
    /// called from the GUI). Pass `nil` from CLI contexts where there's no
    /// bundle (a sensible fallback is used: `command -v seshctl-cli` on PATH,
    /// then `.build/release/seshctl-cli` relative to CWD).
    @discardableResult
    public static func install(bundleURL: URL?, paths: Paths = Paths()) throws -> InstallResult {
        var actions: [Action] = []

        // 1. Resolve CLI source path.
        let cliSource = try resolveCLISource(bundleURL: bundleURL)

        // 2. Symlinks in ~/.local/bin.
        try ensureDirectoryExists(atPath: paths.localBinDir, actions: &actions)
        try createOrReplaceSymlink(
            at: paths.seshctlSymlink, target: cliSource,
            allowMigrateRealFile: false, actions: &actions
        )
        try createOrReplaceSymlink(
            at: paths.seshctlCLISymlink, target: cliSource,
            allowMigrateRealFile: true, actions: &actions
        )

        // 3. Standalone uninstaller script.
        try writeUninstallerScript(paths: paths, actions: &actions)

        // 4. Hook scripts (with defensive guard prepended).
        let hookSourceDirs = try resolveHookSourceDirs(bundleURL: bundleURL)
        try writeHookScripts(
            sourceDir: hookSourceDirs.claude,
            destDir: paths.claudeHooksDir,
            scripts: HookSpec.claudeScriptNames,
            actions: &actions
        )
        try writeHookScripts(
            sourceDir: hookSourceDirs.codex,
            destDir: paths.codexHooksDir,
            scripts: HookSpec.codexScriptNames,
            actions: &actions
        )
        try writeHookScripts(
            sourceDir: hookSourceDirs.cursor,
            destDir: paths.cursorHooksDir,
            scripts: HookSpec.cursorScriptNames,
            actions: &actions
        )

        // 5. Register hooks in Claude Code settings.
        try injectHookEntries(
            settingsPath: paths.claudeSettingsFile,
            entries: HookSpec.claudeEntries(for: paths),
            llm: "claude",
            paths: paths,
            actions: &actions
        )

        // 6. Register hooks in Codex hooks.json.
        try injectHookEntries(
            settingsPath: paths.codexSettingsFile,
            entries: HookSpec.codexEntries(for: paths),
            llm: "codex",
            paths: paths,
            actions: &actions
        )

        // 7. Register hooks in Cursor hooks.json. Cursor's schema is
        //    different from Claude/Codex (camelCase events, flat entries,
        //    top-level `version: 1`), so it uses its own helper.
        try injectCursorHookEntries(
            settingsPath: paths.cursorSettingsFile,
            entries: HookSpec.cursorEntries(for: paths),
            paths: paths,
            actions: &actions
        )

        // 8. Codex config flag.
        try ensureCodexConfigFlag(paths: paths, actions: &actions)

        // 9. Marker file.
        try writeMarkerFile(bundleURL: bundleURL, paths: paths, actions: &actions)

        return InstallResult(actions: actions)
    }

    /// Full uninstall — survives partial state.
    ///
    /// Always removes:
    ///   - Claude Code + Codex hook registrations
    ///   - Hook scripts directory (`~/.local/share/seshctl/hooks/`)
    ///   - CLI symlinks (when they're symlinks)
    ///   - Standalone uninstaller script
    ///   - Application Support directory (includes marker)
    ///   - `hooks = true` line in `~/.agents/config.toml` (and the
    ///     `[features]` header if it ends up empty)
    ///
    /// Conditionally removes when `deleteSessionHistory` is `true`:
    ///   - `~/.local/share/seshctl/seshctl.db` (plus any GRDB `-wal` / `-shm`
    ///     sidecars at the same prefix)
    ///   - `~/.local/share/seshctl/` itself, but ONLY if empty afterwards
    ///     (unrelated user files under that directory survive)
    @discardableResult
    public static func uninstall(
        paths: Paths = Paths(),
        deleteSessionHistory: Bool = false
    ) throws -> UninstallResult {
        var actions: [Action] = []

        // 1. Remove Claude Code hook entries.
        try removeHookEntries(
            settingsPath: paths.claudeSettingsFile,
            entries: HookSpec.claudeEntries(for: paths),
            llm: "claude",
            paths: paths,
            actions: &actions
        )

        // 2. Remove Codex hook entries.
        try removeHookEntries(
            settingsPath: paths.codexSettingsFile,
            entries: HookSpec.codexEntries(for: paths),
            llm: "codex",
            paths: paths,
            actions: &actions
        )

        // 2b. Remove Cursor hook entries (different schema — own helper).
        try removeCursorHookEntries(
            settingsPath: paths.cursorSettingsFile,
            entries: HookSpec.cursorEntries(for: paths),
            paths: paths,
            actions: &actions
        )

        // 3. Remove hook scripts directory.
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.hooksRoot) {
            try fm.removeItem(atPath: paths.hooksRoot)
            actions.append(.removedDirectory(paths.hooksRoot))
        }

        // 4. Remove symlinks (only if symlinks).
        for link in [paths.seshctlSymlink, paths.seshctlCLISymlink] {
            if isSymlink(atPath: link) {
                try fm.removeItem(atPath: link)
                actions.append(.removedSymlink(link))
            }
        }

        // 5. Remove standalone uninstaller.
        if fm.fileExists(atPath: paths.uninstallerScript) {
            try fm.removeItem(atPath: paths.uninstallerScript)
            actions.append(.removedFile(paths.uninstallerScript))
        }

        // 6. Remove application support directory (includes marker file).
        if fm.fileExists(atPath: paths.appSupportDir) {
            try fm.removeItem(atPath: paths.appSupportDir)
            actions.append(.removedDirectory(paths.appSupportDir))
        }

        // 7. Always clear our codex feature flag — it's not user data, it
        //    only ever exists because we wrote it during install.
        try clearCodexConfigFlag(paths: paths, actions: &actions)

        // 8. Optionally remove the session history database (and its GRDB
        //    -wal / -shm sidecars). Off by default — see the CLI's
        //    --delete-history flag and the GUI's checkbox.
        if deleteSessionHistory {
            try removeSessionHistory(paths: paths, actions: &actions)
        }

        // 9. If ~/.local/share/seshctl/ is now empty (hooks removed +
        //    db removed if opted in + no unrelated sibling files), drop it.
        if fm.fileExists(atPath: paths.seshctlDataDir) {
            let contents = (try? fm.contentsOfDirectory(atPath: paths.seshctlDataDir)) ?? []
            if contents.isEmpty {
                try fm.removeItem(atPath: paths.seshctlDataDir)
                actions.append(.removedDirectory(paths.seshctlDataDir))
            }
        }

        return UninstallResult(actions: actions)
    }

    // MARK: Paths

    /// Filesystem paths the installer touches. All paths are derived from
    /// `homeRoot`, which defaults to the current user's home directory but
    /// can be overridden in tests to point at a temp directory.
    public struct Paths: Sendable {
        public let homeRoot: URL

        public init(homeRoot: URL = FileManager.default.homeDirectoryForCurrentUser) {
            self.homeRoot = homeRoot
        }

        public var localBinDir: String {
            homeRoot.appendingPathComponent(".local/bin").path
        }
        public var seshctlSymlink: String {
            homeRoot.appendingPathComponent(".local/bin/seshctl").path
        }
        public var seshctlCLISymlink: String {
            homeRoot.appendingPathComponent(".local/bin/seshctl-cli").path
        }
        public var uninstallerScript: String {
            homeRoot.appendingPathComponent(".local/bin/seshctl-uninstall").path
        }

        public var seshctlDataDir: String {
            homeRoot.appendingPathComponent(".local/share/seshctl").path
        }
        public var sessionDB: String {
            homeRoot.appendingPathComponent(".local/share/seshctl/seshctl.db").path
        }
        public var hooksRoot: String {
            homeRoot.appendingPathComponent(".local/share/seshctl/hooks").path
        }
        public var claudeHooksDir: String {
            homeRoot.appendingPathComponent(".local/share/seshctl/hooks/claude").path
        }
        public var codexHooksDir: String {
            homeRoot.appendingPathComponent(".local/share/seshctl/hooks/codex").path
        }
        public var cursorHooksDir: String {
            homeRoot.appendingPathComponent(".local/share/seshctl/hooks/cursor").path
        }

        public var claudeSettingsFile: String {
            homeRoot.appendingPathComponent(".claude/settings.json").path
        }
        public var codexSettingsFile: String {
            homeRoot.appendingPathComponent(".agents/hooks.json").path
        }
        public var cursorSettingsFile: String {
            homeRoot.appendingPathComponent(".cursor/hooks.json").path
        }
        public var codexConfigFile: String {
            homeRoot.appendingPathComponent(".agents/config.toml").path
        }

        public var appSupportDir: String {
            homeRoot.appendingPathComponent("Library/Application Support/Seshctl").path
        }
        public var markerFile: String {
            homeRoot.appendingPathComponent("Library/Application Support/Seshctl/installed-v1.json").path
        }
    }

    // MARK: Hook spec

    enum HookSpec {
        static let claudeScriptNames = [
            "session-start.sh", "user-prompt.sh", "pre-tool-use.sh",
            "notification.sh", "stop.sh", "session-end.sh",
        ]
        static let codexScriptNames = ["session-start.sh", "user-prompt.sh", "stop.sh"]
        static let cursorScriptNames = [
            "session-start.sh", "user-prompt.sh", "after-agent-response.sh",
            "stop.sh", "session-end.sh",
        ]

        struct Entry {
            let event: String
            let matcher: String
            let command: String
        }

        static func claudeEntries(for paths: Paths) -> [Entry] {
            [
                .init(event: "SessionStart", matcher: "", command: "\(paths.claudeHooksDir)/session-start.sh"),
                .init(event: "UserPromptSubmit", matcher: "", command: "\(paths.claudeHooksDir)/user-prompt.sh"),
                .init(event: "PreToolUse", matcher: "", command: "\(paths.claudeHooksDir)/pre-tool-use.sh"),
                .init(event: "Notification", matcher: "", command: "\(paths.claudeHooksDir)/notification.sh"),
                .init(event: "Stop", matcher: "", command: "\(paths.claudeHooksDir)/stop.sh"),
                .init(event: "SessionEnd", matcher: "", command: "\(paths.claudeHooksDir)/session-end.sh"),
            ]
        }

        static func codexEntries(for paths: Paths) -> [Entry] {
            [
                .init(event: "SessionStart", matcher: "", command: "\(paths.codexHooksDir)/session-start.sh"),
                .init(event: "UserPromptSubmit", matcher: "", command: "\(paths.codexHooksDir)/user-prompt.sh"),
                .init(event: "Stop", matcher: "", command: "\(paths.codexHooksDir)/stop.sh"),
            ]
        }

        /// Cursor 1.7+ hooks.json uses camelCase event names and a flat
        /// `{ "command": "..." }` entry shape (no nested `hooks: [...]`
        /// array, no `matcher`). Entries here are consumed by the
        /// Cursor-specific inject/remove helpers below; `matcher` is set to
        /// `""` for shape parity with the other registries but is unused.
        static func cursorEntries(for paths: Paths) -> [Entry] {
            [
                .init(event: "sessionStart", matcher: "", command: "\(paths.cursorHooksDir)/session-start.sh"),
                .init(event: "beforeSubmitPrompt", matcher: "", command: "\(paths.cursorHooksDir)/user-prompt.sh"),
                .init(event: "afterAgentResponse", matcher: "", command: "\(paths.cursorHooksDir)/after-agent-response.sh"),
                .init(event: "stop", matcher: "", command: "\(paths.cursorHooksDir)/stop.sh"),
                .init(event: "sessionEnd", matcher: "", command: "\(paths.cursorHooksDir)/session-end.sh"),
            ]
        }
    }

    // MARK: Step implementations

    static func resolveCLISource(bundleURL: URL?) throws -> String {
        let fm = FileManager.default

        if let bundleURL {
            let candidate = bundleURL
                .appendingPathComponent("Contents/MacOS/seshctl-cli")
                .path
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
            throw InstallError.cliBinaryNotFound(searched: [candidate])
        }

        // No bundle — try PATH then build/release.
        var searched: [String] = []
        if let onPath = which("seshctl-cli") {
            return onPath
        } else {
            searched.append("$PATH (command -v seshctl-cli)")
        }

        let cwd = fm.currentDirectoryPath
        let buildRelease = (cwd as NSString).appendingPathComponent(".build/release/seshctl-cli")
        searched.append(buildRelease)
        if fm.fileExists(atPath: buildRelease) {
            return buildRelease
        }

        throw InstallError.cliBinaryNotFound(searched: searched)
    }

    static func resolveHookSourceDirs(bundleURL: URL?) throws -> (claude: String, codex: String, cursor: String) {
        let fm = FileManager.default

        // Try the bundle first.
        if let bundleURL {
            let bundleClaude = bundleURL.appendingPathComponent("Contents/Resources/hooks/claude").path
            let bundleCodex = bundleURL.appendingPathComponent("Contents/Resources/hooks/codex").path
            let bundleCursor = bundleURL.appendingPathComponent("Contents/Resources/hooks/cursor").path
            if fm.fileExists(atPath: bundleClaude)
                && fm.fileExists(atPath: bundleCodex)
                && fm.fileExists(atPath: bundleCursor)
            {
                return (bundleClaude, bundleCodex, bundleCursor)
            }
        }

        // Fall back to the repo source tree (the dev / `make install-cli` path).
        let execDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        let candidates: [String] = [
            (execDir as NSString).appendingPathComponent("../../hooks"),
            (execDir as NSString).appendingPathComponent("../hooks"),
            (execDir as NSString).appendingPathComponent("hooks"),
            (execDir as NSString).appendingPathComponent("../../../hooks"),
            (fm.currentDirectoryPath as NSString).appendingPathComponent("hooks"),
        ]

        for cand in candidates {
            let resolved = (cand as NSString).standardizingPath
            let claude = (resolved as NSString).appendingPathComponent("claude")
            let codex = (resolved as NSString).appendingPathComponent("codex")
            let cursor = (resolved as NSString).appendingPathComponent("cursor")
            if fm.fileExists(atPath: claude)
                && fm.fileExists(atPath: codex)
                && fm.fileExists(atPath: cursor)
            {
                return (claude, codex, cursor)
            }
        }

        throw InstallError.hookSourceNotFound(searched: candidates)
    }

    static func ensureDirectoryExists(atPath path: String, actions: inout [Action]) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    static func createOrReplaceSymlink(
        at linkPath: String,
        target: String,
        allowMigrateRealFile: Bool,
        actions: inout [Action]
    ) throws {
        let fm = FileManager.default
        let parent = (linkPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

        // Inspect existing entry at linkPath.
        let attrs = try? fm.attributesOfItem(atPath: linkPath)
        let exists = attrs != nil
        let isLink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink

        if exists {
            if isLink {
                // Read current destination — replace if different.
                let currentDest = try? fm.destinationOfSymbolicLink(atPath: linkPath)
                if currentDest == target {
                    return
                }
                try fm.removeItem(atPath: linkPath)
                try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
                actions.append(.symlinkReplaced(linkPath, target: target))
                return
            } else {
                // Real file at this path. Migration policy:
                //   - For seshctl-cli: this is the legacy `make install` artifact;
                //     replace it with our symlink and log the migration.
                //   - For seshctl: refuse to clobber. (User may have something
                //     unrelated there.)
                if allowMigrateRealFile {
                    try fm.removeItem(atPath: linkPath)
                    try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
                    actions.append(.migratedRealFileToSymlink(linkPath))
                    return
                } else {
                    // Replace anyway — the user's previous file at this path was
                    // ours (or interfering with us); align with the existing
                    // Install.swift behavior of overwriting hook scripts.
                    try fm.removeItem(atPath: linkPath)
                    try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
                    actions.append(.symlinkReplaced(linkPath, target: target))
                    return
                }
            }
        }

        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
        actions.append(.symlinkCreated(linkPath, target: target))
    }

    static func writeUninstallerScript(paths: Paths, actions: inout [Action]) throws {
        let fm = FileManager.default
        let parent = (paths.uninstallerScript as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

        if fm.fileExists(atPath: paths.uninstallerScript) {
            try fm.removeItem(atPath: paths.uninstallerScript)
        }
        try uninstallerScriptContents.write(
            toFile: paths.uninstallerScript, atomically: true, encoding: .utf8
        )
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.uninstallerScript)
        actions.append(.uninstallerScriptWritten(paths.uninstallerScript))
    }

    static func writeHookScripts(
        sourceDir: String,
        destDir: String,
        scripts: [String],
        actions: inout [Action]
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        for name in scripts {
            let src = (sourceDir as NSString).appendingPathComponent(name)
            let dst = (destDir as NSString).appendingPathComponent(name)

            guard fm.fileExists(atPath: src) else {
                throw InstallError.hookSourceNotFound(searched: [src])
            }

            let raw = try String(contentsOfFile: src, encoding: .utf8)
            let withGuard = injectHookGuard(into: raw)

            if fm.fileExists(atPath: dst) {
                try fm.removeItem(atPath: dst)
            }
            try withGuard.write(toFile: dst, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst)
            actions.append(.hookScriptWritten(dst))
        }
    }

    /// Insert the defensive guard block immediately after the `#!` shebang line.
    /// Idempotent — if the guard sentinel is already present, returns input
    /// unchanged.
    static func injectHookGuard(into script: String) -> String {
        if script.contains(hookGuardSentinel) {
            return script
        }

        // Split on first newline.
        guard let firstNewline = script.firstIndex(of: "\n") else {
            // No newline at all — script is just a single line. Append guard
            // after it.
            return script + "\n" + hookGuardBlock + "\n"
        }

        let firstLine = script[..<firstNewline]
        let rest = script[script.index(after: firstNewline)...]

        if firstLine.hasPrefix("#!") {
            return String(firstLine) + "\n" + hookGuardBlock + "\n" + String(rest)
        } else {
            // No shebang — prepend the guard block as the first content.
            return hookGuardBlock + "\n" + script
        }
    }

    static func injectHookEntries(
        settingsPath: String,
        entries: [HookSpec.Entry],
        llm: String,
        paths: Paths,
        actions: inout [Action]
    ) throws {
        let fm = FileManager.default
        let parent = (settingsPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

        // The prefix that identifies a hook command as one we deployed.
        // Anchoring here (instead of a bare "seshctl" substring) keeps us
        // from clobbering unrelated user-defined hooks that happen to have
        // "seshctl" anywhere in their command (e.g. a user's own fork at
        // ~/projects/seshctl-fork/foo.sh).
        let hookPrefix = (llm == "claude")
            ? paths.claudeHooksDir + "/"
            : paths.codexHooksDir + "/"

        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
            if !data.isEmpty {
                do {
                    guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        // Parsed OK but it's not a top-level dictionary
                        // (e.g. the file is a JSON array). Treat the same as
                        // malformed — we'd otherwise overwrite it.
                        throw NSError(domain: "FirstLaunchInstaller", code: 1, userInfo: nil)
                    }
                    settings = parsed
                } catch {
                    let backupPath = settingsPath + ".bak-\(Int(Date().timeIntervalSince1970))"
                    try? fm.copyItem(atPath: settingsPath, toPath: backupPath)
                    throw InstallError.malformedSettings(path: settingsPath, backupPath: backupPath)
                }
            }
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for entry in entries {
            var eventHooks = hooks[entry.event] as? [[String: Any]] ?? []

            let alreadyExists = eventHooks.contains { group in
                guard let groupHooks = group["hooks"] as? [[String: Any]] else { return false }
                return groupHooks.contains { hook in
                    guard let cmd = hook["command"] as? String else { return false }
                    return cmd.hasPrefix(hookPrefix)
                }
            }

            if alreadyExists {
                actions.append(.hookAlreadyRegistered(llm: llm, event: entry.event))
            } else {
                let hookGroup: [String: Any] = [
                    "matcher": entry.matcher,
                    "hooks": [
                        [
                            "type": "command",
                            "command": entry.command,
                        ] as [String: Any]
                    ],
                ]
                eventHooks.append(hookGroup)
                actions.append(.hookRegistered(llm: llm, event: entry.event))
            }

            hooks[entry.event] = eventHooks
        }

        settings["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: settingsPath))
    }

    static func removeHookEntries(
        settingsPath: String,
        entries: [HookSpec.Entry],
        llm: String,
        paths: Paths,
        actions: inout [Action]
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsPath) else { return }

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        guard !data.isEmpty else { return }

        // Mirror injectHookEntries: malformed JSON should NOT be silently
        // ignored. If we can't parse the file, leave it alone and surface
        // an error with a backup pointer so the user can recover.
        var settings: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "FirstLaunchInstaller", code: 1, userInfo: nil)
            }
            settings = parsed
        } catch {
            let backupPath = settingsPath + ".bak-\(Int(Date().timeIntervalSince1970))"
            try? fm.copyItem(atPath: settingsPath, toPath: backupPath)
            throw InstallError.malformedSettings(path: settingsPath, backupPath: backupPath)
        }

        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        // Same anchored-prefix matcher used by injectHookEntries — see the
        // comment there for the rationale. The matcher MUST match on a
        // path prefix (not a bare "seshctl" substring) so we don't strip
        // unrelated user hooks that happen to mention "seshctl".
        let hookPrefix = (llm == "claude")
            ? paths.claudeHooksDir + "/"
            : paths.codexHooksDir + "/"

        for entry in entries {
            guard var eventHooks = hooks[entry.event] as? [[String: Any]] else { continue }

            let beforeCount = eventHooks.count
            eventHooks.removeAll { group in
                guard let groupHooks = group["hooks"] as? [[String: Any]] else { return false }
                return groupHooks.contains { hook in
                    guard let cmd = hook["command"] as? String else { return false }
                    return cmd.hasPrefix(hookPrefix)
                }
            }
            if eventHooks.count != beforeCount {
                actions.append(.removedHookEntry(llm: llm, event: entry.event))
            }

            if eventHooks.isEmpty {
                hooks.removeValue(forKey: entry.event)
            } else {
                hooks[entry.event] = eventHooks
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        let updatedData = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: URL(fileURLWithPath: settingsPath))
    }

    /// Inject seshctl entries into Cursor's `~/.cursor/hooks.json`. Cursor's
    /// schema differs from Claude/Codex in three ways and a separate helper
    /// is cleaner than parameterizing the existing one:
    ///   1. Top-level `version: 1` (Claude/Codex don't have a version field).
    ///   2. Event names are camelCase (`sessionStart`, `afterAgentResponse`,
    ///      etc.) — passed in via the `Entry.event` field by the caller.
    ///   3. Entry shape is flat: `{ "command": "..." }`. There is no nested
    ///      `hooks: [...]` array and no `matcher` sibling.
    ///
    /// Anchored on the deployed hooks dir prefix (same trick as the
    /// Claude/Codex helpers) to avoid touching unrelated user hooks that
    /// happen to mention "seshctl" elsewhere in their command. Idempotent.
    static func injectCursorHookEntries(
        settingsPath: String,
        entries: [HookSpec.Entry],
        paths: Paths,
        actions: inout [Action]
    ) throws {
        let fm = FileManager.default
        let parent = (settingsPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let hookPrefix = paths.cursorHooksDir + "/"

        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
            if !data.isEmpty {
                do {
                    guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw NSError(domain: "FirstLaunchInstaller", code: 1, userInfo: nil)
                    }
                    settings = parsed
                } catch {
                    let backupPath = settingsPath + ".bak-\(Int(Date().timeIntervalSince1970))"
                    try? fm.copyItem(atPath: settingsPath, toPath: backupPath)
                    throw InstallError.malformedSettings(path: settingsPath, backupPath: backupPath)
                }
            }
        }

        // Ensure Cursor's required version field exists.
        if settings["version"] == nil {
            settings["version"] = 1
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for entry in entries {
            var eventHooks = hooks[entry.event] as? [[String: Any]] ?? []

            let alreadyExists = eventHooks.contains { hook in
                guard let cmd = hook["command"] as? String else { return false }
                return cmd.hasPrefix(hookPrefix)
            }

            if alreadyExists {
                actions.append(.hookAlreadyRegistered(llm: "cursor", event: entry.event))
            } else {
                eventHooks.append(["command": entry.command])
                actions.append(.hookRegistered(llm: "cursor", event: entry.event))
            }

            hooks[entry.event] = eventHooks
        }

        settings["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: settingsPath))
    }

    /// Mirror of `removeHookEntries` for Cursor's flat-entry schema.
    /// Same anchored-prefix matcher; drops only entries whose `command`
    /// starts with `paths.cursorHooksDir + "/"`. Leaves user-defined entries
    /// (including those that happen to mention "seshctl" elsewhere)
    /// untouched. Empty event keys are removed; an empty `hooks` dict is
    /// dropped too. The top-level `version` field is preserved so the file
    /// still parses as a valid Cursor hooks.json.
    static func removeCursorHookEntries(
        settingsPath: String,
        entries: [HookSpec.Entry],
        paths: Paths,
        actions: inout [Action]
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsPath) else { return }

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        guard !data.isEmpty else { return }

        var settings: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "FirstLaunchInstaller", code: 1, userInfo: nil)
            }
            settings = parsed
        } catch {
            let backupPath = settingsPath + ".bak-\(Int(Date().timeIntervalSince1970))"
            try? fm.copyItem(atPath: settingsPath, toPath: backupPath)
            throw InstallError.malformedSettings(path: settingsPath, backupPath: backupPath)
        }

        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        let hookPrefix = paths.cursorHooksDir + "/"

        for entry in entries {
            guard var eventHooks = hooks[entry.event] as? [[String: Any]] else { continue }

            let beforeCount = eventHooks.count
            eventHooks.removeAll { hook in
                guard let cmd = hook["command"] as? String else { return false }
                return cmd.hasPrefix(hookPrefix)
            }
            if eventHooks.count != beforeCount {
                actions.append(.removedHookEntry(llm: "cursor", event: entry.event))
            }

            if eventHooks.isEmpty {
                hooks.removeValue(forKey: entry.event)
            } else {
                hooks[entry.event] = eventHooks
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        let updatedData = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: URL(fileURLWithPath: settingsPath))
    }

    /// The Codex feature flag that turns the hooks engine on. Codex 0.153
    /// renamed `codex_hooks` to `hooks`; the old spelling still works but
    /// prints a deprecation warning on every run, so install writes the new
    /// name and migrates any legacy line it finds.
    static let codexHooksFlagLine = "hooks = true"
    static let legacyCodexHooksFlagLine = "codex_hooks = true"

    /// The TOML section our flag lives under. `hooks` is a generic key name,
    /// so every match — read or write — must be scoped to this section:
    /// a `hooks = true` under some other tool's section is not ours.
    static let codexFeaturesHeader = "[features]"

    /// True when `line` is exactly the current flag (ignoring surrounding
    /// whitespace).
    private static func isCurrentCodexFlagLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == codexHooksFlagLine
    }

    /// True when `line` is exactly the deprecated flag spelling.
    private static func isLegacyCodexFlagLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == legacyCodexHooksFlagLine
    }

    /// True when `line` is either spelling of the flag.
    private static func isAnyCodexFlagLine(_ line: String) -> Bool {
        isCurrentCodexFlagLine(line) || isLegacyCodexFlagLine(line)
    }

    /// True when `line` is a TOML section header (`[name]`).
    private static func isTOMLSectionHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
    }

    /// Locates the `[features]` section in `lines`: the index of its header
    /// plus the range of body lines that follow it, up to the next section
    /// header or EOF. The preamble before any header is NOT `[features]`.
    /// Returns `nil` when the file has no `[features]` header.
    private static func codexFeaturesSection(
        in lines: [String]
    ) -> (header: Int, body: Range<Int>)? {
        guard let header = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == codexFeaturesHeader
        }) else { return nil }
        var end = header + 1
        while end < lines.count && !isTOMLSectionHeader(lines[end]) { end += 1 }
        return (header, (header + 1)..<end)
    }

    static func ensureCodexConfigFlag(paths: Paths, actions: inout [Action]) throws {
        let fm = FileManager.default
        let parent = (paths.codexConfigFile as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: paths.codexConfigFile) {
            try "\(codexFeaturesHeader)\n\(codexHooksFlagLine)\n".write(
                toFile: paths.codexConfigFile, atomically: true, encoding: .utf8
            )
            actions.append(.codexConfigUpdated)
            return
        }

        let contents = try String(contentsOfFile: paths.codexConfigFile, encoding: .utf8)
        var lines = contents.components(separatedBy: "\n")

        // Every decision below is scoped to the `[features]` section. A
        // `hooks = true` under any other section belongs to another tool: it
        // must neither satisfy our "already set" check nor be removed.
        let section = codexFeaturesSection(in: lines)
        let body = section.map { Array(lines[$0.body]) } ?? []
        let hasCurrent = body.contains(where: isCurrentCodexFlagLine)
        let hasLegacy = body.contains(where: isLegacyCodexFlagLine)

        if hasCurrent && !hasLegacy {
            actions.append(.codexConfigAlreadySet)
            return
        }

        // Migration: drop any `codex_hooks = true` line inside `[features]`
        // before (re)writing the current flag, otherwise Codex keeps warning
        // about the deprecated key.
        if let section, hasLegacy {
            let kept = lines[section.body].filter { !isLegacyCodexFlagLine($0) }
            lines.replaceSubrange(section.body, with: kept)
        }

        // Removing legacy lines never shifts the header index (it precedes
        // the body), so `section.header` is still valid here.
        let updated: String
        if hasCurrent {
            updated = lines.joined(separator: "\n")
        } else if let section {
            var withFlag = lines
            withFlag.insert(codexHooksFlagLine, at: section.header + 1)
            updated = withFlag.joined(separator: "\n")
        } else {
            updated = lines.joined(separator: "\n")
                + "\n\(codexFeaturesHeader)\n\(codexHooksFlagLine)\n"
        }

        try updated.write(toFile: paths.codexConfigFile, atomically: true, encoding: .utf8)
        actions.append(.codexConfigUpdated)
    }

    /// Mirror of `ensureCodexConfigFlag`, but for uninstall. Drops the
    /// `hooks = true` line (and the deprecated `codex_hooks = true` spelling
    /// we may have written on an older install) from `~/.agents/config.toml`.
    /// Only the `[features]` section is considered — `hooks` is a generic key
    /// name and a same-named key under another section belongs to another
    /// tool. If the
    /// `[features]` section ends up with no keys, drops the header too.
    /// Other sections and keys are left untouched.
    ///
    /// Idempotent: missing file, or no flag line under `[features]` → no-op.
    static func clearCodexConfigFlag(paths: Paths, actions: inout [Action]) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.codexConfigFile) else { return }

        let original = try String(contentsOfFile: paths.codexConfigFile, encoding: .utf8)

        // Walk the file line-by-line, tracking which section we're in. Drop
        // the flag line only inside `[features]`. After the pass,
        // also drop the `[features]` header if that section is empty.
        //
        // A "section" runs from a `[name]` header up to the next header (or
        // EOF). Lines between are either key/value pairs, blanks, or
        // comments. We consider the section "empty" if it has no non-blank,
        // non-comment key lines after the drop.
        struct Section {
            var header: String?         // e.g. "[features]" or nil for the preamble
            var lines: [String] = []    // body lines (NOT including the header itself)
        }

        var sections: [Section] = [Section()]
        let rawLines = original.components(separatedBy: "\n")
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                sections.append(Section(header: line))
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }

        // `hooks` is a generic key name, so only the `[features]` section is
        // ours to edit. A line with the same text under any other section
        // belongs to a different tool — leave it alone. Bail out entirely
        // (no rewrite, no action logged) when [features] has no flag line.
        func isFeaturesSection(_ section: Section) -> Bool {
            section.header?.trimmingCharacters(in: .whitespaces) == codexFeaturesHeader
        }

        guard sections.contains(where: {
            isFeaturesSection($0) && $0.lines.contains(where: isAnyCodexFlagLine)
        }) else { return }

        // Drop the flag line (both spellings) from [features] only.
        for i in sections.indices where isFeaturesSection(sections[i]) {
            sections[i].lines.removeAll(where: isAnyCodexFlagLine)
        }

        // If [features] is now empty, drop the whole section (header + body).
        // "Empty" means: no non-blank, non-comment lines remain.
        sections.removeAll { section in
            guard isFeaturesSection(section) else { return false }
            let hasRealContent = section.lines.contains { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("#")
            }
            return !hasRealContent
        }

        // Rebuild the file.
        var rebuilt: [String] = []
        for section in sections {
            if let header = section.header { rebuilt.append(header) }
            rebuilt.append(contentsOf: section.lines)
        }
        var output = rebuilt.joined(separator: "\n")

        // Collapse runs of 3+ blank lines down to 2 — keeps things tidy when
        // an entire section is removed mid-file. Don't go aggressive on
        // single-blank cleanup; users may have intentional spacing.
        while output.contains("\n\n\n\n") {
            output = output.replacingOccurrences(of: "\n\n\n\n", with: "\n\n\n")
        }

        try output.write(toFile: paths.codexConfigFile, atomically: true, encoding: .utf8)
        actions.append(.codexConfigCleared(paths.codexConfigFile))
    }

    /// Remove `~/.local/share/seshctl/seshctl.db` plus any GRDB `-wal` /
    /// `-shm` sidecar files at the same prefix. Idempotent.
    static func removeSessionHistory(paths: Paths, actions: inout [Action]) throws {
        let fm = FileManager.default
        let dir = paths.seshctlDataDir
        guard fm.fileExists(atPath: dir) else { return }

        let dbName = (paths.sessionDB as NSString).lastPathComponent  // "seshctl.db"
        // Only delete the main DB file and GRDB's own sidecars. Anything else
        // sharing the `seshctl.db` prefix (e.g. a user's `seshctl.db-backup`)
        // is left alone.
        let targets: Set<String> = [
            dbName,
            "\(dbName)-wal",
            "\(dbName)-shm",
            "\(dbName)-journal",
        ]
        let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        for entry in entries {
            guard targets.contains(entry) else { continue }
            let full = (dir as NSString).appendingPathComponent(entry)
            try fm.removeItem(atPath: full)
            actions.append(.removedFile(full))
        }
    }

    static func writeMarkerFile(bundleURL: URL?, paths: Paths, actions: inout [Action]) throws {
        let fm = FileManager.default
        let parent = (paths.markerFile as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let bundlePath = bundleURL?.path ?? ""
        let version = readBundleVersion(bundleURL: bundleURL) ?? "dev"

        // Store `installedAt` as a `Double` (seconds since 1970). The
        // previous ISO 8601 string had 1 s precision, which made
        // `reconcileInstall` fire the refresh path on every launch because
        // file mtimes carry sub-second precision and would read "newer"
        // than the marker's `installedAt`. `currentMarkerState` still
        // accepts the legacy string form for back-compat.
        let installedAt = Date().timeIntervalSince1970

        let payload: [String: Any] = [
            "bundlePath": bundlePath,
            "version": version,
            "installedAt": installedAt,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: paths.markerFile))
        actions.append(.markerFileWritten(paths.markerFile))
    }

    // MARK: Helpers

    static func isSymlink(atPath path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return false
        }
        return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", "command -v \(name) || true"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // command -v with our wrapper may return a shell builtin name; only
        // accept absolute paths to a real executable.
        guard trimmed.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: trimmed)
        else {
            return nil
        }
        return trimmed
    }

    static func readBundleVersion(bundleURL: URL?) -> String? {
        guard let bundleURL else { return nil }
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let obj = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ),
              let dict = obj as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
            ?? dict["CFBundleVersion"] as? String
    }
}

// MARK: - Embedded resources

extension FirstLaunchInstaller {
    /// Sentinel string that marks a hook script as having had the defensive
    /// guard block prepended. Used for idempotent re-injection.
    static let hookGuardSentinel = "# seshctl-defensive-guard-v2"

    /// Defensive guard prepended to every deployed hook script.
    ///
    /// If `seshctl-cli` isn't on PATH the hook no-ops. It self-cleans by
    /// invoking `seshctl-uninstall`, but only when all three hold:
    ///
    ///   1. at least 5 misses have accumulated,
    ///   2. the miss streak has spanned 24h, and
    ///   3. no app bundle is on disk (marker path or `/Applications`).
    ///
    /// Count alone is not enough. `~/.local/bin/seshctl-cli` symlinks into the
    /// bundle, so every reinstall — `make install`, a Sparkle update — unlinks
    /// the target and any hook firing in that window records a miss. v1 gated
    /// on count alone and a run of `make install` cycles was enough to make the
    /// hooks uninstall a perfectly healthy seshctl out from under the user.
    /// Conditions 2 and 3 are what distinguish "user trashed the app" (the case
    /// this exists for) from "app is being replaced right now".
    ///
    /// A legacy v1 miss file carries no `firstMissEpoch`, so the first v2 run
    /// stamps it to now and the 24h clock starts fresh — never retroactively.
    ///
    /// Note: this guard uses `rm -f` on its OWN tracking file — that's fine,
    /// the `trash` rule from AGENTS.md is for the assistant's actions, not for
    /// scripts deployed to user machines.
    static let hookGuardBlock = """
        \(hookGuardSentinel)
        if ! command -v seshctl-cli >/dev/null 2>&1; then
            SESHCTL_STATE="$HOME/Library/Application Support/Seshctl"
            MISS_FILE="$SESHCTL_STATE/hook-misses.json"
            mkdir -p "$SESHCTL_STATE" 2>/dev/null || true
            seshctl_now=$(date -u +%s)
            seshctl_misses=0
            seshctl_first="$seshctl_now"
            if command -v jq >/dev/null 2>&1 && [ -f "$MISS_FILE" ]; then
                seshctl_misses=$(jq -r '.misses // 0' "$MISS_FILE" 2>/dev/null || echo 0)
                seshctl_first=$(jq -r '.firstMissEpoch // empty' "$MISS_FILE" 2>/dev/null || echo "")
                case "$seshctl_first" in ''|*[!0-9]*) seshctl_first="$seshctl_now" ;; esac
            fi
            seshctl_misses=$((seshctl_misses + 1))
            if command -v jq >/dev/null 2>&1; then
                printf '{"misses":%d,"firstMissEpoch":%d,"lastMiss":"%s"}' "$seshctl_misses" "$seshctl_first" "$(date -u +%FT%TZ)" > "$MISS_FILE" 2>/dev/null || true
            fi
            # A dangling CLI symlink means "app deleted" OR "app mid-reinstall".
            # Only the first should self-clean, so require the streak to span a
            # day and the bundle to be genuinely absent. The marker is
            # authoritative about where the bundle lives; /Applications is only
            # consulted when there is no marker to ask, which also keeps this
            # from reading outside $HOME when one is present.
            seshctl_bundle=""
            if command -v jq >/dev/null 2>&1 && [ -f "$SESHCTL_STATE/installed-v1.json" ]; then
                seshctl_bundle=$(jq -r '.bundlePath // empty' "$SESHCTL_STATE/installed-v1.json" 2>/dev/null || echo "")
            fi
            [ -n "$seshctl_bundle" ] || seshctl_bundle="/Applications/Seshctl.app"
            seshctl_gone=1
            [ -d "$seshctl_bundle" ] && seshctl_gone=0
            seshctl_age=$((seshctl_now - seshctl_first))
            if [ "$seshctl_misses" -ge 5 ] && [ "$seshctl_age" -ge 86400 ] && [ "$seshctl_gone" -eq 1 ] && [ -x "$HOME/.local/bin/seshctl-uninstall" ]; then
                "$HOME/.local/bin/seshctl-uninstall" >/dev/null 2>&1 || true
            fi
            exit 0
        fi
        # Reset miss counter on success (binary present).
        rm -f "$HOME/Library/Application Support/Seshctl/hook-misses.json" 2>/dev/null || true
        """

    /// Verbatim contents of `scripts/seshctl-uninstall.sh`. Embedded as a
    /// Swift string so the bundle can drop it into `~/.local/bin/` without
    /// shipping the script as a separate resource.
    ///
    /// **Keep this in sync with `scripts/seshctl-uninstall.sh`** — there's a
    /// parity test in `FirstLaunchInstallerTests` that compares the two
    /// byte-for-byte. Any change must be applied to both copies.
    static let uninstallerScriptContents: String = #"""
        #!/bin/bash
        # seshctl standalone uninstaller.
        #
        # This is a real file in ~/.local/bin/ (not a symlink into the bundle), so it
        # survives even if the user drags Seshctl.app to the Trash. It performs the
        # same cleanup as `FirstLaunchInstaller.uninstall()` but uses only `jq` + shell
        # so it has no dependency on the bundle being present.
        #
        # What gets removed:
        #   - seshctl-tagged hook entries from ~/.claude/settings.json
        #   - seshctl-tagged hook entries from ~/.agents/hooks.json
        #   - seshctl-tagged hook entries from ~/.cursor/hooks.json
        #   - julo15.seshctl extension from VS Code / VS Code Insiders / Cursor (best effort)
        #   - ~/.local/bin/seshctl, ~/.local/bin/seshctl-cli (only if symlinks)
        #   - ~/.local/bin/seshctl-uninstall (this file itself)
        #   - ~/.local/share/seshctl/hooks/  (NOT seshctl.db — that's user data)
        #   - ~/Library/Application Support/Seshctl/
        #   - hooks = true line in ~/.agents/config.toml (and [features] if empty)
        #
        # What this does NOT touch:
        #   - ~/.local/share/seshctl/seshctl.db (user data, kept like `make uninstall`)
        #   - /Applications/Seshctl.app (we'll log a reminder if it's still there)
        #
        # Idempotent: safe to run multiple times.

        set -euo pipefail

        CLAUDE_SETTINGS="$HOME/.claude/settings.json"
        CODEX_HOOKS="$HOME/.agents/hooks.json"
        CURSOR_HOOKS="$HOME/.cursor/hooks.json"
        HOOKS_DIR="$HOME/.local/share/seshctl/hooks"
        HOOK_PREFIX="$HOME/.local/share/seshctl/hooks/"
        CURSOR_HOOK_PREFIX="$HOME/.local/share/seshctl/hooks/cursor/"
        BIN_DIR="$HOME/.local/bin"
        SUPPORT_DIR="$HOME/Library/Application Support/Seshctl"
        APP_BUNDLE="/Applications/Seshctl.app"
        CODEX_CONFIG="$HOME/.agents/config.toml"

        have_jq=1
        if ! command -v jq >/dev/null 2>&1; then
            have_jq=0
            echo "warning: jq not found — falling back to a less robust JSON cleanup." >&2
        fi

        # Strip seshctl-tagged hook entries from a Claude/Codex settings file.
        # A "seshctl-tagged" entry is one whose hooks[].command starts with the
        # deployed hooks dir prefix (~/.local/share/seshctl/hooks/) — same anchored
        # matcher used by the Swift installer. Anchoring keeps us from stripping
        # user-defined hooks that mention "seshctl" elsewhere in their command.
        #
        # An event whose array empties out is dropped with `select`, NOT `|= empty`.
        # jq's `|= empty` sets the key to null rather than deleting it, and Claude Code
        # then refuses the file with `hooks.SessionStart must be an array of matchers;
        # received null` on every launch. The `. // []` coercion additionally cleans up
        # nulls left behind by earlier versions of this script.
        strip_seshctl_hooks() {
            local file="$1"
            [ -f "$file" ] || return 0

            if [ "$have_jq" -eq 1 ]; then
                local tmp
                tmp="$(mktemp)"
                if jq --arg prefix "$HOOK_PREFIX" '
                    if .hooks then
                        .hooks |= with_entries(
                            .value |= ((. // []) | map(select(
                                (.hooks // []) | map(.command // "") | map(startswith($prefix)) | any | not
                            )))
                            | select((.value | length) > 0)
                        )
                        | (if (.hooks | length) == 0 then del(.hooks) else . end)
                    else . end
                ' "$file" > "$tmp" 2>/dev/null; then
                    mv "$tmp" "$file"
                    echo "  cleaned $file"
                else
                    rm -f "$tmp"
                    echo "  warning: could not parse $file — left untouched" >&2
                fi
            else
                # Minimal fallback: just leave a backup and warn. We don't try to
                # hand-edit JSON without jq — too risky.
                cp "$file" "$file.seshctl-uninstall.bak"
                echo "  warning: leaving $file untouched (no jq); backup at $file.seshctl-uninstall.bak" >&2
            fi
        }

        # Strip seshctl-tagged hook entries from a Cursor hooks.json file.
        # Cursor's schema is FLAT: `{ "version": 1, "hooks": { "<event>": [{ "command": "..." }] } }`
        # — no nested `hooks: [...]` array, no `matcher` key. We anchor on the cursor
        # hooks dir prefix (~/.local/share/seshctl/hooks/cursor/) to drop only the
        # entries we installed. Events that become empty are left as `[]` to mirror
        # what the Swift `removeCursorHookEntries` would leave if we never touched the
        # event key at all — user-defined entries under any event are preserved, and
        # the top-level `version` is left intact (Cursor needs it to parse the file).
        strip_seshctl_cursor_hooks() {
            local file="$1"
            if [ ! -f "$file" ]; then
                echo "  $file: not present, skipping"
                return 0
            fi

            if [ "$have_jq" -eq 1 ]; then
                local tmp
                tmp="$(mktemp)"
                if jq --arg prefix "$CURSOR_HOOK_PREFIX" '
                    if .hooks then
                        .hooks |= (
                            to_entries
                            | map(.value |= map(select(
                                ((.command // "") | startswith($prefix)) | not
                              )))
                            | from_entries
                        )
                    else . end
                ' "$file" > "$tmp" 2>/dev/null; then
                    mv "$tmp" "$file"
                    echo "  cleaned $file"
                else
                    rm -f "$tmp"
                    echo "  warning: could not parse $file — left untouched" >&2
                fi
            else
                cp "$file" "$file.seshctl-uninstall.bak"
                echo "  warning: leaving $file untouched (no jq); backup at $file.seshctl-uninstall.bak" >&2
            fi
        }

        echo "==> Removing seshctl hook entries from settings files"
        strip_seshctl_hooks "$CLAUDE_SETTINGS"
        strip_seshctl_hooks "$CODEX_HOOKS"
        strip_seshctl_cursor_hooks "$CURSOR_HOOKS"

        # Best-effort: tell each supported editor to uninstall julo15.seshctl. Mirrors
        # ExtensionInstaller.uninstallAllEditorExtensions in Swift, but here we don't
        # have NSWorkspace — we hard-code the canonical /Applications paths and fall
        # back to PATH for users who relocated the editor or only have its CLI shim.
        # Every failure is logged and swallowed: a broken editor must never block the
        # rest of the teardown.
        uninstall_editor_extension() {
            local label="$1"
            local app_path="$2"
            local cli_name="$3"
            local cli="${app_path}/Contents/Resources/app/bin/${cli_name}"
            if [ ! -x "$cli" ]; then
                cli="$(command -v "$cli_name" 2>/dev/null || true)"
            fi
            if [ -z "$cli" ] || [ ! -x "$cli" ]; then
                return 0
            fi
            if ! "$cli" --list-extensions 2>/dev/null | grep -qx 'julo15.seshctl'; then
                return 0
            fi
            if "$cli" --uninstall-extension julo15.seshctl >/dev/null 2>&1; then
                echo "  removed extension from ${label}"
            else
                echo "  warning: failed to uninstall extension from ${label}" >&2
            fi
        }

        echo "==> Uninstalling Seshctl extension from editors"
        uninstall_editor_extension "VS Code" "/Applications/Visual Studio Code.app" "code"
        uninstall_editor_extension "VS Code Insiders" "/Applications/Visual Studio Code - Insiders.app" "code-insiders"
        uninstall_editor_extension "Cursor" "/Applications/Cursor.app" "cursor"

        echo "==> Removing CLI symlinks from $BIN_DIR"
        for link in "$BIN_DIR/seshctl" "$BIN_DIR/seshctl-cli"; do
            if [ -L "$link" ]; then
                rm -f "$link"
                echo "  removed symlink $link"
            elif [ -e "$link" ]; then
                echo "  skipping $link (real file, not a symlink — leaving it alone)"
            fi
        done

        echo "==> Removing hook scripts directory"
        if [ -d "$HOOKS_DIR" ]; then
            rm -rf "$HOOKS_DIR"
            echo "  removed $HOOKS_DIR"
        fi

        echo "==> Clearing Codex hooks flag from $CODEX_CONFIG"
        if [ -f "$CODEX_CONFIG" ]; then
            # One section-aware pass mirroring the Swift clearCodexConfigFlag:
            #   - drop the flag line (current `hooks` and deprecated `codex_hooks`
            #     spellings) ONLY while inside [features]. `hooks` is a generic key
            #     name; a same-named key under another section belongs to some other
            #     tool and must survive untouched.
            #   - drop the [features] header too when the section ends up with no
            #     real (non-blank, non-comment) keys — install only writes
            #     [features] / hooks when we put it there, so cleaning it up is part
            #     of "leave no trace."
            # awk exits 0 only if it actually removed a flag line, so an untouched
            # config is never rewritten.
            if awk '
                BEGIN { in_features=0; kept=0; buf=""; cleared=0 }
                /^[[:space:]]*\[/ {
                    # Section header. Anything buffered belongs to a [features]
                    # section that never showed a real key — drop it.
                    buf=""
                    kept=0
                    if ($0 ~ /^[[:space:]]*\[features\][[:space:]]*$/) {
                        in_features=1
                        buf=$0
                    } else {
                        in_features=0
                        print
                    }
                    next
                }
                in_features==1 && /^[[:space:]]*(codex_)?hooks = true[[:space:]]*$/ {
                    cleared=1
                    next
                }
                in_features==1 && kept==0 && ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) {
                    # Blank or comment before any real key — buffer it; the whole
                    # section may still turn out to be ours to delete.
                    buf = buf "\n" $0
                    next
                }
                in_features==1 && kept==0 {
                    # First real key: [features] survives. Flush the buffered header
                    # (plus any blanks/comments) and print this line too.
                    print buf
                    buf=""
                    kept=1
                    print
                    next
                }
                { print }
                END {
                    if (cleared == 1) { exit 0 }
                    exit 1
                }
            ' "$CODEX_CONFIG" > "$CODEX_CONFIG.tmp"; then
                mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"
                echo "  cleared hooks = true from $CODEX_CONFIG"
            else
                rm -f "$CODEX_CONFIG.tmp"
            fi
        fi

        echo "==> Removing application support directory"
        if [ -d "$SUPPORT_DIR" ]; then
            rm -rf "$SUPPORT_DIR"
            echo "  removed $SUPPORT_DIR"
        fi

        for candidate in "/Applications/Seshctl.app" "$HOME/Applications/Seshctl.app" "$HOME/Downloads/Seshctl.app"; do
            if [ -d "$candidate" ]; then
                echo "Seshctl.app is still installed at $candidate — drag it to Trash to complete uninstall."
                break
            fi
        done

        # Self-delete last so the rest of the script always runs first.
        SELF="$BIN_DIR/seshctl-uninstall"
        if [ -f "$SELF" ]; then
            rm -f "$SELF"
        fi

        echo ""
        echo "seshctl uninstalled."

        """#
}
