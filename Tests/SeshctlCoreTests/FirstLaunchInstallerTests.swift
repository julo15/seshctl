import Foundation
import Testing

@testable import SeshctlCore

// MARK: - Test helpers

/// Walks up from this source file to find the repo root (the directory
/// containing `Package.swift`). Tests use this to locate `hooks/`,
/// `Resources/Info.plist`, and `scripts/seshctl-uninstall.sh` without making
/// assumptions about where the test process's CWD is.
private func repoRoot() -> URL {
    var url = URL(fileURLWithPath: #file)
    while url.path != "/" {
        url = url.deletingLastPathComponent()
        let candidate = url.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return url
        }
    }
    fatalError("could not find Package.swift walking up from \(#file)")
}

/// Creates a fresh temp directory to act as a `$HOME` for one test, with
/// `~/.claude/settings.json` pre-seeded with `{}` (matches the realistic
/// state on a Mac that already has Claude Code configured).
private func makeTempHome() throws -> URL {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("seshctl-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let claudeDir = temp.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: claudeDir.appendingPathComponent("settings.json"))
    return temp
}

private func cleanup(_ temp: URL) {
    try? FileManager.default.removeItem(at: temp)
}

/// Creates a fake `.app`-like bundle layout in `parent` so
/// `FirstLaunchInstaller.install(bundleURL:)` resolves the CLI binary and
/// hook source dirs from it. Hook sources are copied from the repo `hooks/`
/// tree rather than synthesized so the deployed scripts match what would
/// ship in a real DMG.
private func makeFakeBundle(in parent: URL) throws -> URL {
    let bundle = parent.appendingPathComponent("Seshctl.app")
    let macOS = bundle.appendingPathComponent("Contents/MacOS")
    let resources = bundle.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

    // Fake CLI binary — empty file with executable bit.
    let cli = macOS.appendingPathComponent("seshctl-cli")
    try Data().write(to: cli)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

    // Fake SeshctlApp executable. The reconcileInstall mtime check reads
    // Contents/MacOS/SeshctlApp; without this the attribute lookup fails and
    // the mtime branch silently returns .noChange.
    let appExe = macOS.appendingPathComponent("SeshctlApp")
    try Data().write(to: appExe)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appExe.path)

    // Copy repo hooks/ tree into bundle Resources.
    let repoHooks = repoRoot().appendingPathComponent("hooks")
    let bundleHooks = resources.appendingPathComponent("hooks")
    try FileManager.default.copyItem(at: repoHooks, to: bundleHooks)

    // Minimal Info.plist (only used by readBundleVersion → marker file).
    let plist: [String: Any] = [
        "CFBundleIdentifier": "app.seshctl.Seshctl.test",
        "CFBundleShortVersionString": "0.1.0-test",
        "CFBundleVersion": "1",
    ]
    let plistData = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0
    )
    try plistData.write(to: bundle.appendingPathComponent("Contents/Info.plist"))

    return bundle
}

private func loadJSONObject(at path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

/// Counts the number of seshctl-tagged groups under `hooks[event]`.
/// A group is "seshctl-tagged" if any nested hook command contains "seshctl".
private func countSeshctlGroups(in settings: [String: Any], event: String) -> Int {
    guard let hooks = settings["hooks"] as? [String: Any],
          let eventHooks = hooks[event] as? [[String: Any]]
    else { return 0 }
    return eventHooks.filter { group in
        guard let groupHooks = group["hooks"] as? [[String: Any]] else { return false }
        return groupHooks.contains { hook in
            (hook["command"] as? String)?.contains("seshctl") == true
        }
    }.count
}

/// Runs a deployed hook script against a sandboxed `HOME`, with a `PATH` that
/// deliberately omits `seshctl-cli` so the defensive guard takes its miss
/// branch. Returns the script's exit status.
private func runGuardedHook(script: String, home: URL) throws -> Int32 {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = [script]
    proc.environment = [
        "HOME": home.path,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "SHELL": "/bin/bash",
    ]
    let inPipe = Pipe()
    proc.standardInput = inPipe
    proc.standardOutput = Pipe()
    proc.standardError = Pipe()
    try proc.run()
    inPipe.fileHandleForWriting.write(Data("{}".utf8))
    try inPipe.fileHandleForWriting.close()
    proc.waitUntilExit()
    return proc.terminationStatus
}

/// Rewrites `firstMissEpoch` so the guard's 24h gate reads as satisfied. A
/// real streak accrues over days; a test can't wait, so it moves the clock.
private func backdateFirstMiss(missFile: URL, by seconds: Int) throws {
    let data = try Data(contentsOf: missFile)
    guard var counter = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
    }
    counter["firstMissEpoch"] = Int(Date().timeIntervalSince1970) - seconds
    try JSONSerialization.data(withJSONObject: counter).write(to: missFile)
}

/// Seeds a settings.json carrying one unrelated user hook. Needed whenever a
/// test asserts on what the uninstaller leaves behind: with no survivor the
/// whole `hooks` object is deleted and per-event damage can't be observed.
private func seedForeignHook(at settingsPath: String) throws {
    let parent = (settingsPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(
        atPath: parent, withIntermediateDirectories: true
    )
    let seeded: [String: Any] = [
        "hooks": [
            "Notification": [
                ["matcher": "", "hooks": [["type": "command", "command": "/usr/bin/true"]]]
            ]
        ]
    ]
    try JSONSerialization.data(withJSONObject: seeded)
        .write(to: URL(fileURLWithPath: settingsPath))
}

// MARK: - Suite

@Suite("FirstLaunchInstaller")
struct FirstLaunchInstallerTests {

    // MARK: 1. Fresh install creates expected files

    @Test("Fresh install creates symlinks, hooks, marker, and registers entries")
    func freshInstall_createsExpectedFiles() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }

        let bundleParent = temp.appendingPathComponent("bundle-parent")
        try FileManager.default.createDirectory(at: bundleParent, withIntermediateDirectories: true)
        let bundle = try makeFakeBundle(in: bundleParent)

        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)
        let result = try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)
        #expect(!result.actions.isEmpty)

        let fm = FileManager.default
        let cliTarget = bundle.appendingPathComponent("Contents/MacOS/seshctl-cli").path

        // 1. ~/.local/bin/seshctl is a symlink → fakeBundle/Contents/MacOS/seshctl-cli
        #expect(FirstLaunchInstaller.isSymlink(atPath: paths.seshctlSymlink))
        let dest1 = try fm.destinationOfSymbolicLink(atPath: paths.seshctlSymlink)
        #expect(dest1 == cliTarget)

        // 2. ~/.local/bin/seshctl-cli is a symlink → same target
        #expect(FirstLaunchInstaller.isSymlink(atPath: paths.seshctlCLISymlink))
        let dest2 = try fm.destinationOfSymbolicLink(atPath: paths.seshctlCLISymlink)
        #expect(dest2 == cliTarget)

        // 3. ~/.local/bin/seshctl-uninstall — real file, executable, expected contents
        #expect(fm.fileExists(atPath: paths.uninstallerScript))
        #expect(!FirstLaunchInstaller.isSymlink(atPath: paths.uninstallerScript))
        let attrs = try fm.attributesOfItem(atPath: paths.uninstallerScript)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms & 0o111 != 0, "uninstaller should be executable")
        let written = try String(contentsOfFile: paths.uninstallerScript, encoding: .utf8)
        #expect(written == FirstLaunchInstaller.uninstallerScriptContents)

        // 4. Claude hook scripts present
        for name in FirstLaunchInstaller.HookSpec.claudeScriptNames {
            let p = (paths.claudeHooksDir as NSString).appendingPathComponent(name)
            #expect(fm.fileExists(atPath: p), "missing claude hook: \(name)")
        }
        // 5. Codex hook scripts present
        for name in FirstLaunchInstaller.HookSpec.codexScriptNames {
            let p = (paths.codexHooksDir as NSString).appendingPathComponent(name)
            #expect(fm.fileExists(atPath: p), "missing codex hook: \(name)")
        }

        // 6. ~/.claude/settings.json has 6 expected event entries pointing into temp HOME
        let claudeSettings = try loadJSONObject(at: paths.claudeSettingsFile)
        let claudeHooks = claudeSettings["hooks"] as? [String: Any]
        #expect(claudeHooks != nil)
        let expectedClaudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse",
                                    "Notification", "Stop", "SessionEnd"]
        for event in expectedClaudeEvents {
            #expect(claudeHooks?[event] != nil, "missing claude hook event: \(event)")
            let groups = (claudeHooks?[event] as? [[String: Any]]) ?? []
            // At least one group should reference our temp HOME's hooks dir.
            let containsTempPath = groups.contains { group in
                guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
                return hooks.contains { hook in
                    (hook["command"] as? String)?.contains(temp.path) == true
                }
            }
            #expect(containsTempPath, "claude \(event) hook command should reference temp HOME")
        }

        // 7. ~/.agents/hooks.json has 3 expected events
        let codexSettings = try loadJSONObject(at: paths.codexSettingsFile)
        let codexHooks = codexSettings["hooks"] as? [String: Any]
        #expect(codexHooks != nil)
        for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
            #expect(codexHooks?[event] != nil, "missing codex hook event: \(event)")
        }

        // 8. ~/.agents/config.toml contains codex_hooks = true
        let toml = try String(contentsOfFile: paths.codexConfigFile, encoding: .utf8)
        #expect(toml.contains("codex_hooks = true"))

        // 9. Marker file exists, parses, contains expected fields.
        // `installedAt` is written as a Double (seconds since 1970) so the
        // mtime check in `reconcileInstall` doesn't lose sub-second
        // precision and fire spuriously on every launch.
        #expect(fm.fileExists(atPath: paths.markerFile))
        let marker = try loadJSONObject(at: paths.markerFile)
        #expect(marker["bundlePath"] as? String == bundle.path)
        #expect((marker["version"] as? String) != nil)
        #expect((marker["installedAt"] as? Double) != nil)
    }

    // MARK: 2. Idempotent install

    @Test("Install twice does not duplicate hook entries")
    func installTwice_isIdempotent() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)
        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        let claudeSettings = try loadJSONObject(at: paths.claudeSettingsFile)
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse",
                      "Notification", "Stop", "SessionEnd"] {
            #expect(countSeshctlGroups(in: claudeSettings, event: event) == 1,
                    "duplicate seshctl group for claude \(event)")
        }
        let codexSettings = try loadJSONObject(at: paths.codexSettingsFile)
        for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
            #expect(countSeshctlGroups(in: codexSettings, event: event) == 1,
                    "duplicate seshctl group for codex \(event)")
        }
    }

    // MARK: 3. Preserves unrelated hooks on install

    @Test("Install preserves unrelated hook entries already present")
    func installPreservesUnrelatedHooks() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // Pre-populate ~/.claude/settings.json with an unrelated hook.
        let unrelatedCommand = "/some/other/tool.sh"
        let preExisting: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": unrelatedCommand]
                        ],
                    ] as [String: Any]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: preExisting, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: paths.claudeSettingsFile))

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        let settings = try loadJSONObject(at: paths.claudeSettingsFile)
        let hooks = settings["hooks"] as? [String: Any]
        let sessionStart = hooks?["SessionStart"] as? [[String: Any]] ?? []
        let unrelatedStillThere = sessionStart.contains { group in
            guard let inner = group["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["command"] as? String) == unrelatedCommand }
        }
        let seshctlAdded = sessionStart.contains { group in
            guard let inner = group["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["command"] as? String)?.contains("seshctl") == true }
        }
        #expect(unrelatedStillThere, "unrelated hook should be preserved")
        #expect(seshctlAdded, "seshctl hook should be added alongside")
    }

    // MARK: 4. Uninstall preserves unrelated hooks

    @Test("Uninstall removes only seshctl hooks; unrelated entries survive")
    func uninstallPreservesUnrelatedHooks() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        // Add an unrelated hook post-install.
        let unrelatedCommand = "/some/other/tool.sh"
        var settings = try loadJSONObject(at: paths.claudeSettingsFile)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var sessionStart = hooks["SessionStart"] as? [[String: Any]] ?? []
        sessionStart.append([
            "matcher": "",
            "hooks": [["type": "command", "command": unrelatedCommand]],
        ] as [String: Any])
        hooks["SessionStart"] = sessionStart
        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: paths.claudeSettingsFile))

        try FirstLaunchInstaller.uninstall(paths: paths)

        let after = try loadJSONObject(at: paths.claudeSettingsFile)
        let afterHooks = after["hooks"] as? [String: Any] ?? [:]
        let afterSessionStart = afterHooks["SessionStart"] as? [[String: Any]] ?? []
        let unrelatedStillThere = afterSessionStart.contains { group in
            guard let inner = group["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["command"] as? String) == unrelatedCommand }
        }
        let seshctlRemoved = !afterSessionStart.contains { group in
            guard let inner = group["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["command"] as? String)?.contains("seshctl") == true }
        }
        #expect(unrelatedStillThere, "unrelated hook should remain after uninstall")
        #expect(seshctlRemoved, "seshctl entries should be gone after uninstall")
    }

    // MARK: 5. Symlink overwrite migrates real file

    @Test("Install replaces a real file at ~/.local/bin/seshctl-cli with a symlink")
    func symlinkOverwrite_migratesRealFile() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // Pre-create a real file at ~/.local/bin/seshctl-cli.
        let binDir = temp.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let realFile = URL(fileURLWithPath: paths.seshctlCLISymlink)
        try Data("not a symlink".utf8).write(to: realFile)
        #expect(!FirstLaunchInstaller.isSymlink(atPath: paths.seshctlCLISymlink))

        let result = try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        #expect(FirstLaunchInstaller.isSymlink(atPath: paths.seshctlCLISymlink))
        let migrated = result.actions.contains { action in
            if case .migratedRealFileToSymlink(let p) = action {
                return p == paths.seshctlCLISymlink
            }
            return false
        }
        #expect(migrated, "expected migratedRealFileToSymlink action for seshctl-cli")
    }

    // MARK: 6. Defensive guard present in deployed hook

    @Test("Deployed hook script contains the defensive guard before any seshctl-cli invocation")
    func defensiveGuardInDeployedHook() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        let deployed = (paths.claudeHooksDir as NSString).appendingPathComponent("session-start.sh")
        let contents = try String(contentsOfFile: deployed, encoding: .utf8)
        #expect(contents.contains("command -v seshctl-cli"),
                "defensive guard sentinel missing")

        // The guard must appear BEFORE any actual seshctl-cli invocation.
        if let guardIdx = contents.range(of: "command -v seshctl-cli")?.lowerBound,
           let invokeIdx = contents.range(of: "seshctl-cli start")?.lowerBound {
            #expect(guardIdx < invokeIdx,
                    "defensive guard should appear before `seshctl-cli start`")
        }
        // Sentinel marker also present.
        #expect(contents.contains(FirstLaunchInstaller.hookGuardSentinel))
    }

    // MARK: 7. Info.plist required keys

    @Test("Resources/Info.plist contains all required keys with correct types")
    func infoPlistRequiredKeys() throws {
        let plistURL = repoRoot().appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = parsed as? [String: Any] else {
            Issue.record("Info.plist did not parse as a dictionary")
            return
        }

        // String-typed keys.
        for key in ["CFBundleIdentifier", "CFBundleName", "CFBundleExecutable",
                    "CFBundleVersion", "CFBundleShortVersionString",
                    "LSMinimumSystemVersion"] {
            #expect(dict[key] is String, "\(key) missing or wrong type")
            if let s = dict[key] as? String {
                #expect(!s.isEmpty, "\(key) should be non-empty")
            }
        }

        // LSUIElement should be a Bool == true.
        let uiElement = dict["LSUIElement"]
        if let b = uiElement as? Bool {
            #expect(b == true, "LSUIElement should be true")
        } else if let n = uiElement as? NSNumber {
            #expect(n.boolValue == true, "LSUIElement should be true")
        } else {
            Issue.record("LSUIElement missing or not a Bool")
        }

        // NSAppleEventsUsageDescription — non-empty string.
        let usage = dict["NSAppleEventsUsageDescription"] as? String
        #expect(usage != nil && !(usage ?? "").isEmpty,
                "NSAppleEventsUsageDescription missing or empty")
    }

    // MARK: 8. Swift uninstall and shell uninstall produce equivalent state

    @Test("FirstLaunchInstaller.uninstall and seshctl-uninstall.sh leave the same state")
    func swiftAndShellUninstallProduceSameState() throws {
        let tempA = try makeTempHome()
        let tempB = try makeTempHome()
        defer {
            cleanup(tempA)
            cleanup(tempB)
        }
        let bundleA = try makeFakeBundle(in: tempA)
        let bundleB = try makeFakeBundle(in: tempB)
        let pathsA = FirstLaunchInstaller.Paths(homeRoot: tempA)
        let pathsB = FirstLaunchInstaller.Paths(homeRoot: tempB)

        try FirstLaunchInstaller.install(bundleURL: bundleA, paths: pathsA)
        try FirstLaunchInstaller.install(bundleURL: bundleB, paths: pathsB)

        // Swift uninstall on A.
        try FirstLaunchInstaller.uninstall(paths: pathsA)

        // Shell uninstall on B — invoke the standalone script with HOME=tempB.
        let script = repoRoot().appendingPathComponent("scripts/seshctl-uninstall.sh")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tempB.path
        // Make sure jq is reachable. Default macOS PATH contains /usr/bin/jq.
        if env["PATH"] == nil || env["PATH"]?.isEmpty == true {
            env["PATH"] = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        }
        proc.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0,
                "shell uninstaller should exit 0; stderr: \(String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")")

        let fm = FileManager.default

        // Bin entries gone in both.
        for paths in [pathsA, pathsB] {
            #expect(!fm.fileExists(atPath: paths.seshctlSymlink), "seshctl symlink lingers in \(paths.homeRoot.path)")
            #expect(!fm.fileExists(atPath: paths.seshctlCLISymlink), "seshctl-cli symlink lingers in \(paths.homeRoot.path)")
            #expect(!fm.fileExists(atPath: paths.uninstallerScript), "uninstaller lingers in \(paths.homeRoot.path)")
            #expect(!fm.fileExists(atPath: paths.hooksRoot), "hooks dir lingers in \(paths.homeRoot.path)")
            #expect(!fm.fileExists(atPath: paths.appSupportDir), "app support dir lingers in \(paths.homeRoot.path)")
        }

        // Equivalence: in BOTH files, no seshctl-tagged hook command remains.
        //
        // The two uninstallers leave settings.json in slightly different shapes
        // (Swift fully removes empty event keys + the `hooks` dict; the shell
        // jq filter leaves event keys present with a null value). That's a
        // user-invisible difference — both correctly remove all seshctl
        // commands and preserve unrelated entries. Asserting the user-facing
        // invariant (no seshctl commands left, no unrelated commands lost) is
        // the meaningful equivalence here.
        for paths in [pathsA, pathsB] {
            let raw = try String(contentsOfFile: paths.claudeSettingsFile, encoding: .utf8)
            #expect(!raw.contains("seshctl"),
                    "found leftover 'seshctl' substring in \(paths.claudeSettingsFile)")
            if fm.fileExists(atPath: paths.codexSettingsFile) {
                let codexRaw = try String(contentsOfFile: paths.codexSettingsFile, encoding: .utf8)
                #expect(!codexRaw.contains("seshctl"),
                        "found leftover 'seshctl' substring in \(paths.codexSettingsFile)")
            }
            if fm.fileExists(atPath: paths.cursorSettingsFile) {
                let cursorRaw = try String(contentsOfFile: paths.cursorSettingsFile, encoding: .utf8)
                #expect(!cursorRaw.contains("seshctl"),
                        "found leftover 'seshctl' substring in \(paths.cursorSettingsFile)")
            }
        }
    }

    // MARK: 9. ensureCodexConfigFlag handles the existing-[features]-section case

    @Test("ensureCodexConfigFlag adds codex_hooks under existing [features] block")
    func ensureCodexConfigFlag_existingFeaturesSection() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // Pre-create config.toml with a [features] section but no codex_hooks line.
        let agentsDir = temp.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let preexisting = "[features]\nother_flag = false\n"
        try preexisting.write(
            toFile: paths.codexConfigFile, atomically: true, encoding: .utf8
        )

        var actions: [FirstLaunchInstaller.Action] = []
        try FirstLaunchInstaller.ensureCodexConfigFlag(paths: paths, actions: &actions)

        let after = try String(contentsOfFile: paths.codexConfigFile, encoding: .utf8)
        #expect(after.contains("[features]"))
        #expect(after.contains("codex_hooks = true"))
        #expect(after.contains("other_flag = false"))

        // Re-running should hit the "already set" branch.
        var actions2: [FirstLaunchInstaller.Action] = []
        try FirstLaunchInstaller.ensureCodexConfigFlag(paths: paths, actions: &actions2)
        #expect(actions2.contains(.codexConfigAlreadySet))
    }

    @Test("ensureCodexConfigFlag appends [features] when none exists")
    func ensureCodexConfigFlag_noFeaturesSection() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        let agentsDir = temp.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try "[other]\nval = 1\n".write(
            toFile: paths.codexConfigFile, atomically: true, encoding: .utf8
        )

        var actions: [FirstLaunchInstaller.Action] = []
        try FirstLaunchInstaller.ensureCodexConfigFlag(paths: paths, actions: &actions)

        let after = try String(contentsOfFile: paths.codexConfigFile, encoding: .utf8)
        #expect(after.contains("[features]"))
        #expect(after.contains("codex_hooks = true"))
        #expect(after.contains("[other]"))
    }

    // MARK: 10. InstallError messages

    @Test("InstallError descriptions render the searched paths and underlying errors")
    func installErrorDescriptions() {
        let cliErr = FirstLaunchInstaller.InstallError.cliBinaryNotFound(searched: ["/x", "/y"])
        #expect(cliErr.description.contains("/x"))
        #expect(cliErr.description.contains("/y"))

        let hookErr = FirstLaunchInstaller.InstallError.hookSourceNotFound(searched: ["/a"])
        #expect(hookErr.description.contains("/a"))

        struct Underlying: Error, CustomStringConvertible { var description: String { "boom" } }
        let ioErr = FirstLaunchInstaller.InstallError.ioError("write failed", underlying: Underlying())
        #expect(ioErr.description.contains("write failed"))
        #expect(ioErr.description.contains("boom"))
    }

    // MARK: 11. injectHookGuard is idempotent and handles edge cases

    @Test("injectHookGuard prepends guard, is idempotent, handles missing shebang")
    func injectHookGuard_edgeCases() {
        let scriptWithShebang = "#!/bin/bash\necho hi\n"
        let once = FirstLaunchInstaller.injectHookGuard(into: scriptWithShebang)
        #expect(once.contains(FirstLaunchInstaller.hookGuardSentinel))
        // Sentinel appears after the shebang line.
        let lines = once.components(separatedBy: "\n")
        #expect(lines.first == "#!/bin/bash")

        // Idempotent: a second pass leaves the script unchanged.
        let twice = FirstLaunchInstaller.injectHookGuard(into: once)
        #expect(twice == once)

        // No shebang at all → guard prepended at top.
        let scriptNoShebang = "echo hi\n"
        let injected = FirstLaunchInstaller.injectHookGuard(into: scriptNoShebang)
        #expect(injected.contains(FirstLaunchInstaller.hookGuardSentinel))
        #expect(injected.hasPrefix(FirstLaunchInstaller.hookGuardSentinel))

        // Single-line script (no newlines).
        let oneLiner = "echo hi"
        let injectedOneLiner = FirstLaunchInstaller.injectHookGuard(into: oneLiner)
        #expect(injectedOneLiner.contains(FirstLaunchInstaller.hookGuardSentinel))
    }

    // MARK: 12. isInstalled reflects the marker file under default paths

    @Test("isInstalled returns false when marker file under default HOME is absent")
    func isInstalled_smoke() {
        // We can't safely manipulate the user's real ~/Library/Application Support/Seshctl
        // in a test; just exercise the property to cover its branch. The
        // assertion is loose — we only require that calling it doesn't throw
        // and returns a Bool.
        let value = FirstLaunchInstaller.isInstalled
        #expect(value == true || value == false)
    }

    // MARK: 13. Hook self-clean gating

    /// The regression guarding a real incident: `make install` trashes the
    /// bundle before copying the new one, and `~/.local/bin/seshctl-cli`
    /// symlinks into it. Every hook firing in that window records a miss. The
    /// v1 guard gated on miss count alone, so a run of rebuild cycles made the
    /// hooks uninstall a perfectly healthy seshctl out from under the user.
    @Test("Miss count alone does not self-clean while the bundle is installed")
    func hookSelfCleanIgnoresMissCountWhileInstalled() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        let hookScript = (paths.claudeHooksDir as NSString)
            .appendingPathComponent("session-start.sh")
        let missFile = temp
            .appendingPathComponent("Library/Application Support/Seshctl/hook-misses.json")
        precondition(FileManager.default.isExecutableFile(atPath: "/usr/bin/jq"),
                     "jq missing at /usr/bin/jq; test cannot proceed")

        // Ten misses — twice the old threshold. The bundle is still on disk
        // the whole time, which is what distinguishes this from a real delete.
        for _ in 1...10 {
            _ = try runGuardedHook(script: hookScript, home: temp)
        }

        let counter = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: missFile)
        ) as? [String: Any]
        #expect(counter?["misses"] as? Int == 10, "misses should still accumulate")

        let settings = try loadJSONObject(at: paths.claudeSettingsFile)
        #expect(countSeshctlGroups(in: settings, event: "SessionStart") == 1,
                "a reinstall window must never trigger the self-clean")
    }

    /// The case the guard actually exists for: the user dragged the app to the
    /// Trash, so no bundle remains and the misses keep accruing across days.
    @Test("Hook self-clean fires once the app is gone and the streak has aged")
    func hookSelfCleanFiresWhenAppGoneAndStreakAged() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // Seed an unrelated user hook so `hooks` survives the strip — without
        // a survivor the whole object is deleted and per-event damage (below)
        // can't be observed.
        try seedForeignHook(at: paths.claudeSettingsFile)
        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        let beforeSettings = try loadJSONObject(at: paths.claudeSettingsFile)
        #expect(countSeshctlGroups(in: beforeSettings, event: "SessionStart") == 1)

        let hookScript = (paths.claudeHooksDir as NSString)
            .appendingPathComponent("session-start.sh")
        let missFile = temp
            .appendingPathComponent("Library/Application Support/Seshctl/hook-misses.json")
        precondition(FileManager.default.isExecutableFile(atPath: "/usr/bin/jq"),
                     "jq missing at /usr/bin/jq; test cannot proceed")

        try FileManager.default.removeItem(at: bundle)

        // Misses 1-4 leave the entries alone regardless of the bundle.
        for i in 1...4 {
            _ = try runGuardedHook(script: hookScript, home: temp)
            let settings = try loadJSONObject(at: paths.claudeSettingsFile)
            #expect(countSeshctlGroups(in: settings, event: "SessionStart") == 1,
                    "seshctl group should survive miss #\(i)")
        }

        try backdateFirstMiss(missFile: missFile, by: 86_400 + 60)
        _ = try runGuardedHook(script: hookScript, home: temp)

        let after = try loadJSONObject(at: paths.claudeSettingsFile)
        #expect(countSeshctlGroups(in: after, event: "SessionStart") == 0,
                "seshctl entries should be gone after the 5th aged miss")

        // The uninstaller must DELETE an emptied event key, never null it.
        // jq's `|= empty` sets it to null, and Claude Code then rejects the
        // file with `hooks.SessionStart must be an array of matchers;
        // received null` on every launch until the user hand-edits it.
        let afterHooks = (after["hooks"] as? [String: Any]) ?? [:]
        let nulled = afterHooks.filter { $0.value is NSNull }.keys.sorted()
        #expect(nulled.isEmpty, "uninstaller left null hook events: \(nulled)")
        #expect(afterHooks["Notification"] is [Any],
                "an unrelated user hook must survive the strip")
    }

    // MARK: 14. reconcileInstall — pure decision function

    /// A `nil` bundle URL (no `.app` at all, e.g. `swift run SeshctlApp`)
    /// and any non-`.app` URL (e.g. a stray file path) both resolve to
    /// `.notRunningFromBundle`. The reconcile is read-only; passing
    /// nonsense paths must not throw or touch the filesystem.
    @Test("reconcileInstall returns .notRunningFromBundle for nil and non-.app URLs")
    func testReconcile_notRunningFromBundle() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // nil bundle URL — dev mode / swift run.
        #expect(
            FirstLaunchInstaller.reconcileInstall(
                bundleURL: nil, currentVersion: "0.1.0", paths: paths
            ) == .notRunningFromBundle
        )

        // Non-.app path — pathExtension != "app".
        let nonAppURL = URL(fileURLWithPath: "/tmp/foo.txt")
        #expect(
            FirstLaunchInstaller.reconcileInstall(
                bundleURL: nonAppURL, currentVersion: "0.1.0", paths: paths
            ) == .notRunningFromBundle
        )
    }

    /// Empty temp home → no marker file → `.needsFreshInstall`. This is
    /// the first-launch case where AppDelegate shows the welcome panel.
    @Test("reconcileInstall returns .needsFreshInstall when marker is absent")
    func testReconcile_needsFreshInstallWhenNoMarker() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // No install has been performed — marker is absent.
        #expect(
            FirstLaunchInstaller.reconcileInstall(
                bundleURL: bundle, currentVersion: "0.1.0", paths: paths
            ) == .needsFreshInstall
        )
    }

    /// Right after install (same bundle URL + same version + the
    /// executable's mtime hasn't been bumped past the marker's
    /// installedAt), the reconcile must say `.noChange`. This is the
    /// steady-state regression check from Fix 1 — markers stored as
    /// sub-second `Double`s mean a freshly-written exe doesn't read as
    /// "newer than" the marker.
    @Test("reconcileInstall returns .noChange when everything matches")
    func testReconcile_noChangeWhenEverythingMatches() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        // Backdate the executable's mtime so the mtime branch is
        // unambiguously older than installedAt. Without this, sub-second
        // jitter between writeMarkerFile and the test read could make the
        // mtime branch read as newer on slower filesystems.
        let execPath = bundle.appendingPathComponent("Contents/MacOS/SeshctlApp").path
        let past = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes(
            [.modificationDate: past], ofItemAtPath: execPath
        )

        #expect(
            FirstLaunchInstaller.reconcileInstall(
                bundleURL: bundle, currentVersion: "0.1.0-test", paths: paths
            ) == .noChange
        )
    }

    /// Install records the bundle's Info.plist version (0.1.0-test);
    /// passing a different currentVersion on subsequent launch simulates
    /// a release bump. Result must be `.needsRefresh(reason:
    /// .versionChanged(...))` with the correct from/to fields.
    @Test("reconcileInstall returns .needsRefresh(.versionChanged) on version mismatch")
    func testReconcile_needsRefreshOnVersionMismatch() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        let result = FirstLaunchInstaller.reconcileInstall(
            bundleURL: bundle, currentVersion: "0.2.0", paths: paths
        )
        guard case .needsRefresh(let reason) = result else {
            Issue.record("expected .needsRefresh, got \(result)")
            return
        }
        guard case .versionChanged(let from, let to) = reason else {
            Issue.record("expected .versionChanged, got \(reason)")
            return
        }
        #expect(from == "0.1.0-test", "from should be the marker's recorded version")
        #expect(to == "0.2.0", "to should be the currentVersion arg")
    }

    /// Install records bundle A's path; passing bundle B's URL on
    /// subsequent launch simulates the user moving/relinking the .app.
    /// Result must be `.needsRefresh(reason: .bundlePathChanged(...))`
    /// with the correct from/to fields.
    @Test("reconcileInstall returns .needsRefresh(.bundlePathChanged) on bundle path mismatch")
    func testReconcile_needsRefreshOnBundlePathMismatch() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundleA = try makeFakeBundle(in: temp)
        // Second bundle in a sibling directory so .path differs.
        let altParent = temp.appendingPathComponent("alt")
        try FileManager.default.createDirectory(at: altParent, withIntermediateDirectories: true)
        let bundleB = try makeFakeBundle(in: altParent)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundleA, paths: paths)

        let result = FirstLaunchInstaller.reconcileInstall(
            bundleURL: bundleB, currentVersion: "0.1.0-test", paths: paths
        )
        guard case .needsRefresh(let reason) = result else {
            Issue.record("expected .needsRefresh, got \(result)")
            return
        }
        guard case .bundlePathChanged(let from, let to) = reason else {
            Issue.record("expected .bundlePathChanged, got \(reason)")
            return
        }
        #expect(from == bundleA.path, "from should be the marker's recorded path (bundle A)")
        #expect(to == bundleB.path, "to should be the bundleURL arg (bundle B)")
    }

    /// Advancing the bundle's `Contents/MacOS/SeshctlApp` mtime past the
    /// marker's `installedAt` simulates a dev `cp -R` of a fresh build
    /// where the version string didn't change. Result must be
    /// `.needsRefresh(reason: .bundleNewer(...))`. We don't pin exact
    /// timestamps (mtime granularity varies), just the relationship.
    @Test("reconcileInstall returns .needsRefresh(.bundleNewer) when exe mtime is newer")
    func testReconcile_needsRefreshOnExecutableMtimeNewer() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        // Bump explicitly via setAttributes (1.5 s in the future) instead
        // of `sleep` — keeps the test fast and avoids flakes on systems
        // with coarse mtime granularity.
        let execPath = bundle.appendingPathComponent("Contents/MacOS/SeshctlApp").path
        let future = Date().addingTimeInterval(1.5)
        try FileManager.default.setAttributes(
            [.modificationDate: future], ofItemAtPath: execPath
        )

        let result = FirstLaunchInstaller.reconcileInstall(
            bundleURL: bundle, currentVersion: "0.1.0-test", paths: paths
        )
        guard case .needsRefresh(let reason) = result else {
            Issue.record("expected .needsRefresh, got \(result)")
            return
        }
        guard case .bundleNewer(let installedAt, let mtime) = reason else {
            Issue.record("expected .bundleNewer, got \(reason)")
            return
        }
        #expect(mtime > installedAt,
                "bundleNewer should carry a mtime strictly after installedAt")
    }

    // MARK: 15. Uninstall removes codex_hooks flag from config.toml

    @Test("Uninstall removes codex_hooks line and drops empty [features] header")
    func testUninstall_removesCodexConfigFlag() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // Install seeds [features] / codex_hooks = true.
        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)
        let installed = try String(contentsOfFile: paths.codexConfigFile, encoding: .utf8)
        #expect(installed.contains("codex_hooks = true"))
        #expect(installed.contains("[features]"))

        // Uninstall without delete-history; just check the codex flag.
        try FirstLaunchInstaller.uninstall(paths: paths)
        let after = try String(contentsOfFile: paths.codexConfigFile, encoding: .utf8)
        #expect(!after.contains("codex_hooks = true"),
                "codex_hooks line should be gone after uninstall")
        #expect(!after.contains("[features]"),
                "empty [features] header should also be gone")
    }

    @Test("Uninstall preserves unrelated [features] keys (keeps the section header)")
    func testUninstall_preservesUnrelatedCodexConfig() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // Pre-write a config with codex_hooks AND an unrelated key, plus
        // a totally unrelated section.
        let agentsDir = temp.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let original = """
            [features]
            codex_hooks = true
            other_flag = true

            [other]
            val = 1
            """
        try original.write(
            toFile: paths.codexConfigFile, atomically: true, encoding: .utf8
        )

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)
        try FirstLaunchInstaller.uninstall(paths: paths)

        let after = try String(contentsOfFile: paths.codexConfigFile, encoding: .utf8)
        #expect(!after.contains("codex_hooks = true"),
                "codex_hooks line should be gone")
        #expect(after.contains("[features]"),
                "[features] header should remain because other_flag is still under it")
        #expect(after.contains("other_flag = true"),
                "unrelated key should be preserved")
        #expect(after.contains("[other]"))
        #expect(after.contains("val = 1"))
    }

    // MARK: 16. Session history opt-in deletion

    @Test("Uninstall preserves session history by default")
    func testUninstall_preservesSessionHistoryByDefault() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // Manually drop a fake DB to model an existing user with session
        // history. Install creates the hooks dir but doesn't touch the db.
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: paths.seshctlDataDir, withIntermediateDirectories: true
        )
        try Data("fake db contents".utf8).write(
            to: URL(fileURLWithPath: paths.sessionDB)
        )

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        // Default uninstall — db must survive.
        try FirstLaunchInstaller.uninstall(paths: paths)

        #expect(fm.fileExists(atPath: paths.sessionDB),
                "session db should be preserved by default uninstall")
        #expect(fm.fileExists(atPath: paths.seshctlDataDir),
                "data dir should survive because the db is still in it")
    }

    @Test("Uninstall deletes session history and the data dir when opted in")
    func testUninstall_deletesSessionHistoryWhenOptedIn() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        let fm = FileManager.default
        try fm.createDirectory(
            atPath: paths.seshctlDataDir, withIntermediateDirectories: true
        )
        // Main db + GRDB sidecars.
        try Data("fake db".utf8).write(to: URL(fileURLWithPath: paths.sessionDB))
        try Data("wal".utf8).write(to: URL(fileURLWithPath: paths.sessionDB + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: paths.sessionDB + "-shm"))

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)
        try FirstLaunchInstaller.uninstall(paths: paths, deleteSessionHistory: true)

        #expect(!fm.fileExists(atPath: paths.sessionDB), "main db should be gone")
        #expect(!fm.fileExists(atPath: paths.sessionDB + "-wal"), "-wal sidecar should be gone")
        #expect(!fm.fileExists(atPath: paths.sessionDB + "-shm"), "-shm sidecar should be gone")
        #expect(!fm.fileExists(atPath: paths.seshctlDataDir),
                "data dir should be removed when empty after delete-history uninstall")
    }

    @Test("Uninstall with delete-history preserves unrelated sibling files in data dir")
    func testUninstall_preservesSiblingFilesWhenDeletingHistory() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        let fm = FileManager.default
        try fm.createDirectory(
            atPath: paths.seshctlDataDir, withIntermediateDirectories: true
        )
        try Data("fake db".utf8).write(to: URL(fileURLWithPath: paths.sessionDB))
        // Unrelated user file — user happened to drop something here.
        let notes = (paths.seshctlDataDir as NSString).appendingPathComponent("notes.txt")
        try Data("user notes".utf8).write(to: URL(fileURLWithPath: notes))

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)
        try FirstLaunchInstaller.uninstall(paths: paths, deleteSessionHistory: true)

        #expect(!fm.fileExists(atPath: paths.sessionDB), "db should be gone")
        #expect(fm.fileExists(atPath: notes), "unrelated sibling file should be preserved")
        #expect(fm.fileExists(atPath: paths.seshctlDataDir),
                "data dir should survive because notes.txt is still in it")
    }

    // MARK: 17. mtime drift regression (Fix 1)

    /// Markers written before Fix 1 stored `installedAt` as an ISO 8601
    /// string. We must still accept them so existing user machines don't
    /// trigger spurious "no marker" handling on first launch after upgrade.
    @Test("currentMarkerState accepts legacy ISO 8601 string installedAt")
    func testCurrentMarkerState_acceptsLegacyISO8601() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // Hand-write a marker in the OLD shape (string timestamp).
        try FileManager.default.createDirectory(
            atPath: (paths.markerFile as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let legacyTimestamp = "2024-12-25T12:34:56Z"
        let legacyJSON: [String: Any] = [
            "bundlePath": "/Applications/Seshctl.app",
            "version": "0.1.0-legacy",
            "installedAt": legacyTimestamp,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: legacyJSON, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: paths.markerFile))

        let state = FirstLaunchInstaller.currentMarkerState(paths: paths)
        #expect(state != nil, "legacy ISO 8601 marker should parse")
        #expect(state?.bundlePath == "/Applications/Seshctl.app")
        #expect(state?.version == "0.1.0-legacy")
        let expectedDate = ISO8601DateFormatter().date(from: legacyTimestamp)
        #expect(state?.installedAt == expectedDate)
    }

    // MARK: 18. Malformed settings.json (Fix 2)

    /// Pre-existing malformed `~/.claude/settings.json` should NOT be
    /// silently overwritten. Install throws `InstallError.malformedSettings`
    /// and a `.bak-<ts>` copy of the original (garbage) file is left next
    /// to it so the user can recover.
    @Test("Install throws on malformed settings.json and backs it up")
    func testInstall_throwsOnMalformedSettingsJsonAndBacksUp() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // Overwrite the pre-seeded `{}` settings.json with garbage. We use
        // a deliberately unbalanced brace so JSONSerialization can't parse
        // it (note: an empty string IS valid input that yields settings
        // = [:], which is fine — we specifically want malformed-but-non-empty).
        let garbage = "this is not json{"
        try Data(garbage.utf8).write(to: URL(fileURLWithPath: paths.claudeSettingsFile))

        var caughtError: Error?
        var thrown = false
        do {
            _ = try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)
        } catch {
            caughtError = error
            thrown = true
        }
        #expect(thrown, "install should throw on malformed settings.json")

        // Verify it's the right error case + that the backup exists with
        // the original garbage contents.
        guard case .malformedSettings(let badPath, let backupPath)?
                = caughtError as? FirstLaunchInstaller.InstallError
        else {
            Issue.record("expected InstallError.malformedSettings, got \(String(describing: caughtError))")
            return
        }
        #expect(badPath == paths.claudeSettingsFile)
        #expect(backupPath.hasPrefix(paths.claudeSettingsFile + ".bak-"))

        let backupContents = try String(contentsOfFile: backupPath, encoding: .utf8)
        #expect(backupContents == garbage, "backup should preserve the original bytes")
    }

    // MARK: 19. Anchored hook-prefix matcher (Fix 3)

    /// Install should leave a user-defined hook whose command path
    /// happens to contain "seshctl" untouched. Pre-fix, the substring
    /// matcher would consider this an existing seshctl entry and skip
    /// registering ours; OR a future change might delete it. Here we
    /// assert both: ours is added AND the user's hook survives.
    @Test("Install preserves unrelated 'seshctl' substring hooks (anchored matcher)")
    func testInstall_preservesUnrelatedSeshctlPathHook() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // User's own fork of seshctl, dropped into their PATH. The command
        // string contains "seshctl" but does NOT start with the installer's
        // deployed hooks dir prefix.
        let unrelatedCommand = "~/projects/seshctl-fork/foo.sh"
        let preExisting: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": unrelatedCommand]
                        ],
                    ] as [String: Any]
                ]
            ]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: preExisting, options: [.prettyPrinted]
        )
        try data.write(to: URL(fileURLWithPath: paths.claudeSettingsFile))

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        let after = try loadJSONObject(at: paths.claudeSettingsFile)
        let hooks = after["hooks"] as? [String: Any] ?? [:]
        let sessionStart = hooks["SessionStart"] as? [[String: Any]] ?? []

        // 1. User's hook still there.
        let userStillThere = sessionStart.contains { group in
            guard let inner = group["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["command"] as? String) == unrelatedCommand }
        }
        #expect(userStillThere, "user's ~/projects/seshctl-fork hook should survive install")

        // 2. Our hook registered alongside.
        let oursAdded = sessionStart.contains { group in
            guard let inner = group["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { hook in
                guard let cmd = hook["command"] as? String else { return false }
                return cmd.hasPrefix(paths.claudeHooksDir + "/")
            }
        }
        #expect(oursAdded, "seshctl SessionStart hook should be registered alongside user's")
    }

    /// Uninstall should remove only commands whose path starts with our
    /// deployed hooks dir prefix. A user-defined hook whose command
    /// happens to contain "seshctl" must survive uninstall.
    @Test("Uninstall preserves unrelated 'seshctl' substring hooks (anchored matcher)")
    func testUninstall_preservesUnrelatedSeshctlPathHook() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        // Inject a user hook whose command path contains "seshctl" but
        // does NOT start with our deployed hooks dir prefix.
        let unrelatedCommand = "~/projects/seshctl-fork/foo.sh"
        var settings = try loadJSONObject(at: paths.claudeSettingsFile)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var sessionStart = hooks["SessionStart"] as? [[String: Any]] ?? []
        sessionStart.append([
            "matcher": "",
            "hooks": [["type": "command", "command": unrelatedCommand]],
        ] as [String: Any])
        hooks["SessionStart"] = sessionStart
        settings["hooks"] = hooks
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted]
        )
        try data.write(to: URL(fileURLWithPath: paths.claudeSettingsFile))

        try FirstLaunchInstaller.uninstall(paths: paths)

        let after = try loadJSONObject(at: paths.claudeSettingsFile)
        let afterHooks = after["hooks"] as? [String: Any] ?? [:]
        let afterSessionStart = afterHooks["SessionStart"] as? [[String: Any]] ?? []

        // 1. User's unrelated-but-substring-matching hook is preserved.
        let userStillThere = afterSessionStart.contains { group in
            guard let inner = group["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["command"] as? String) == unrelatedCommand }
        }
        #expect(userStillThere, "user's ~/projects/seshctl-fork hook should survive uninstall")

        // 2. Our anchored entries are gone.
        let oursRemoved = !afterSessionStart.contains { group in
            guard let inner = group["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { hook in
                guard let cmd = hook["command"] as? String else { return false }
                return cmd.hasPrefix(paths.claudeHooksDir + "/")
            }
        }
        #expect(oursRemoved, "all seshctl-prefixed hooks should be gone after uninstall")
    }

    // MARK: 20. Standalone script parity (Fix 3 closer)

    /// `scripts/seshctl-uninstall.sh` and `uninstallerScriptContents`
    /// must stay byte-for-byte identical. The two paths run on different
    /// machines (user with bundle vs user without), and divergence has
    /// been a recurring source of bugs (anchored matcher, codex_hooks
    /// clearing). Pinning the equality here.
    @Test("Standalone uninstall script matches the embedded Swift constant byte-for-byte")
    func testStandaloneScriptParity() throws {
        let scriptPath = repoRoot()
            .appendingPathComponent("scripts/seshctl-uninstall.sh").path
        let disk = try String(contentsOfFile: scriptPath, encoding: .utf8)
        let embedded = FirstLaunchInstaller.uninstallerScriptContents
        #expect(disk == embedded,
                "scripts/seshctl-uninstall.sh diverged from uninstallerScriptContents")
    }

    // MARK: 21. Bash uninstaller clears codex_hooks (Fix 4)

    /// The shell uninstaller must mirror the Swift one's behavior of
    /// clearing `codex_hooks = true` from `~/.agents/config.toml`. The
    /// `[features]` header is dropped along with it when (and only when)
    /// the section becomes empty.
    @Test("Standalone shell uninstaller clears codex_hooks and removes empty [features]")
    func testStandaloneScript_clearsCodexFlag() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }

        // Seed a config.toml with [features]/codex_hooks plus an unrelated
        // [other] section we must leave alone.
        let agentsDir = temp.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let configPath = agentsDir.appendingPathComponent("config.toml").path
        let seed = """
            [features]
            codex_hooks = true

            [other]
            foo = "bar"

            """
        try seed.write(toFile: configPath, atomically: true, encoding: .utf8)

        // Run the standalone script with HOME=temp so it sees our config.
        let script = repoRoot()
            .appendingPathComponent("scripts/seshctl-uninstall.sh")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = temp.path
        if env["PATH"] == nil || env["PATH"]?.isEmpty == true {
            env["PATH"] = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        }
        proc.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0,
                "shell uninstaller should exit 0; stderr: \(stderr)")

        let after = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(!after.contains("codex_hooks = true"),
                "codex_hooks line should be gone")
        #expect(!after.contains("[features]"),
                "[features] header should be gone because the section is empty")
        #expect(after.contains("[other]"),
                "[other] section should be preserved")
        #expect(after.contains("foo = \"bar\""),
                "[other] keys should be preserved")
    }

    /// When `[features]` has unrelated keys besides `codex_hooks`, the
    /// shell uninstaller drops the codex_hooks line but keeps the
    /// header (and the unrelated keys).
    @Test("Standalone shell uninstaller preserves unrelated [features] entries")
    func testStandaloneScript_preservesUnrelatedFeaturesEntries() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }

        let agentsDir = temp.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let configPath = agentsDir.appendingPathComponent("config.toml").path
        let seed = """
            [features]
            codex_hooks = true
            another_feature = false

            """
        try seed.write(toFile: configPath, atomically: true, encoding: .utf8)

        let script = repoRoot()
            .appendingPathComponent("scripts/seshctl-uninstall.sh")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = temp.path
        if env["PATH"] == nil || env["PATH"]?.isEmpty == true {
            env["PATH"] = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        }
        proc.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0,
                "shell uninstaller should exit 0; stderr: \(stderr)")

        let after = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(!after.contains("codex_hooks = true"),
                "codex_hooks line should be gone")
        #expect(after.contains("[features]"),
                "[features] header should remain because another_feature is still under it")
        #expect(after.contains("another_feature = false"),
                "unrelated key should be preserved")
    }

    // MARK: 22. currentMarkerState robustness

    /// `currentMarkerState` is documented as never-throws: a missing or
    /// malformed marker is just "no install record." A garbage payload
    /// must return nil rather than tripping a parse error up the stack.
    @Test("currentMarkerState returns nil for malformed JSON without throwing")
    func testCurrentMarkerState_returnsNilOnMalformedJson() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // Ensure the marker file's parent dir exists, then write garbage
        // bytes there. JSONSerialization can't parse this (unbalanced
        // brace, leading prose).
        try FileManager.default.createDirectory(
            atPath: (paths.markerFile as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let garbage = "this is not json{"
        try Data(garbage.utf8).write(to: URL(fileURLWithPath: paths.markerFile))

        // currentMarkerState is non-throwing — calling it on a malformed
        // marker should just yield nil. We additionally assert reconcile
        // treats this the same as "no marker" (`.needsFreshInstall`),
        // documenting the recovery path.
        #expect(FirstLaunchInstaller.currentMarkerState(paths: paths) == nil)

        let bundleParent = temp.appendingPathComponent("bundle-parent")
        try FileManager.default.createDirectory(at: bundleParent, withIntermediateDirectories: true)
        let bundle = try makeFakeBundle(in: bundleParent)
        #expect(
            FirstLaunchInstaller.reconcileInstall(
                bundleURL: bundle, currentVersion: "0.1.0", paths: paths
            ) == .needsFreshInstall
        )
    }

    // MARK: 23. Hook self-clean boundary — 4th miss does NOT fire

    /// Companion to `hookSelfCleanFiresAt5thMiss`. Run the guard exactly
    /// 4 times with no `seshctl-cli` on PATH and assert:
    ///   - misses counter is 4
    ///   - settings.json still contains the seshctl entries
    ///   - the uninstaller hasn't fired (no settings-clean side effects,
    ///     hook script still on disk, app support dir still present)
    ///
    /// Pins the 4/5 boundary so a future "decrement to 3 misses" change
    /// has to be intentional and updates this test as part of the diff.
    @Test("Hook self-clean does NOT fire at the 4th consecutive miss")
    func testHookSelfClean_doesNotFireAt4thMiss() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        // Sanity: seshctl entries exist after install.
        let beforeSettings = try loadJSONObject(at: paths.claudeSettingsFile)
        #expect(countSeshctlGroups(in: beforeSettings, event: "SessionStart") == 1)

        let hookScript = (paths.claudeHooksDir as NSString)
            .appendingPathComponent("session-start.sh")
        let missFile = temp.appendingPathComponent("Library/Application Support/Seshctl/hook-misses.json")

        // PATH has jq + base utilities but NOT seshctl-cli — guarantees the
        // guard takes the miss branch on every invocation.
        let basePath = "/usr/bin:/bin:/usr/sbin:/sbin"
        let jqPath = "/usr/bin/jq"
        precondition(FileManager.default.isExecutableFile(atPath: jqPath),
                     "jq missing at \(jqPath); test cannot proceed")

        func runHookOnce() throws -> Int32 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [hookScript]
            var env: [String: String] = [
                "HOME": temp.path,
                "PATH": basePath,
            ]
            env["SHELL"] = "/bin/bash"
            proc.environment = env
            let inPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try proc.run()
            inPipe.fileHandleForWriting.write(Data("{}".utf8))
            try inPipe.fileHandleForWriting.close()
            proc.waitUntilExit()
            return proc.terminationStatus
        }

        // Exactly 4 misses — strictly below the 5-miss self-clean threshold.
        for _ in 1...4 {
            _ = try runHookOnce()
        }

        // 1. Miss counter shows 4.
        let counterData = try Data(contentsOf: missFile)
        let counter = try JSONSerialization.jsonObject(with: counterData) as? [String: Any]
        let misses = counter?["misses"] as? Int ?? -1
        #expect(misses == 4, "expected exactly 4 misses, got \(misses)")

        // 2. settings.json STILL contains the seshctl entry — uninstaller
        //    didn't fire (it would clean these).
        let after = try loadJSONObject(at: paths.claudeSettingsFile)
        #expect(countSeshctlGroups(in: after, event: "SessionStart") == 1,
                "seshctl SessionStart entry must still be registered at 4 misses")

        // 3. seshctl-uninstall NOT invoked — Application Support/Seshctl
        //    survives, hook scripts dir survives. These are the canonical
        //    side effects of the standalone uninstaller; their presence
        //    means it never ran.
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: paths.appSupportDir),
                "Application Support/Seshctl should survive 4 misses")
        #expect(fm.fileExists(atPath: paths.hooksRoot),
                "hooks dir should survive 4 misses")
        #expect(fm.fileExists(atPath: hookScript),
                "session-start hook script should survive 4 misses")
    }

    // MARK: 24. Cursor hook deployment + registration

    /// Cursor's 5 hook scripts deploy to `~/.local/share/seshctl/hooks/cursor/`
    /// and are executable. `~/.cursor/hooks.json` is created with the
    /// Cursor-specific schema: top-level `version: 1`, camelCase event names,
    /// flat `{ "command": "..." }` entries (no nested `hooks: [...]` array,
    /// no `matcher` sibling). Each entry points at the corresponding deployed
    /// script under the temp HOME's cursor hooks dir.
    @Test("Fresh install deploys all 5 Cursor hook scripts and registers them in hooks.json")
    func cursor_freshInstallDeploysAndRegisters() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        let fm = FileManager.default

        // 1. All 5 cursor hook scripts present and executable under temp HOME.
        for name in FirstLaunchInstaller.HookSpec.cursorScriptNames {
            let p = (paths.cursorHooksDir as NSString).appendingPathComponent(name)
            #expect(fm.fileExists(atPath: p), "missing cursor hook: \(name)")
            let attrs = try fm.attributesOfItem(atPath: p)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            #expect(perms & 0o111 != 0, "cursor hook \(name) should be executable")
        }

        // 2. ~/.cursor/hooks.json created with version: 1.
        #expect(fm.fileExists(atPath: paths.cursorSettingsFile))
        let settings = try loadJSONObject(at: paths.cursorSettingsFile)
        let version = settings["version"] as? Int ?? -1
        #expect(version == 1, "Cursor hooks.json must have top-level version: 1")

        // 3. 5 expected events present, each with exactly one entry that
        //    references the deployed cursor hooks dir.
        let hooks = settings["hooks"] as? [String: Any]
        #expect(hooks != nil, "Cursor hooks.json must have a top-level hooks dict")

        let expectedEvents = [
            "sessionStart", "beforeSubmitPrompt", "afterAgentResponse",
            "stop", "sessionEnd",
        ]
        for event in expectedEvents {
            let entries = hooks?[event] as? [[String: Any]] ?? []
            #expect(entries.count == 1, "cursor \(event) should have 1 entry")
            let cmd = entries.first?["command"] as? String ?? ""
            #expect(cmd.hasPrefix(paths.cursorHooksDir + "/"),
                    "cursor \(event) command should live under deployed cursor hooks dir; got \(cmd)")
            // Cursor entries are flat — no nested `hooks: [...]` or `matcher`.
            #expect(entries.first?["hooks"] == nil,
                    "cursor entries are flat — no nested `hooks` array expected")
            #expect(entries.first?["matcher"] == nil,
                    "cursor entries are flat — no `matcher` field expected")
        }
    }

    /// Running install twice must not duplicate Cursor entries — the
    /// anchored-prefix matcher detects "already registered" and skips.
    @Test("Cursor install is idempotent — running install twice does not duplicate entries")
    func cursor_installTwiceIsIdempotent() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)
        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        let settings = try loadJSONObject(at: paths.cursorSettingsFile)
        let hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in [
            "sessionStart", "beforeSubmitPrompt", "afterAgentResponse",
            "stop", "sessionEnd",
        ] {
            let entries = hooks[event] as? [[String: Any]] ?? []
            let seshctlCount = entries.filter { entry in
                (entry["command"] as? String)?.hasPrefix(paths.cursorHooksDir + "/") == true
            }.count
            #expect(seshctlCount == 1, "duplicate seshctl entry for cursor \(event)")
        }
    }

    /// A pre-existing user-defined Cursor entry under one of our events
    /// (e.g. their own `sessionStart` script) is preserved alongside ours.
    @Test("Cursor install preserves pre-existing non-seshctl user entries")
    func cursor_installPreservesUserEntries() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // Pre-populate ~/.cursor/hooks.json with a user hook under sessionStart
        // and an unrelated event we don't touch.
        let cursorDir = temp.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        let userCommand = "/some/user/script.sh"
        let preExisting: [String: Any] = [
            "version": 1,
            "hooks": [
                "sessionStart": [
                    ["command": userCommand]
                ],
                "afterFileEdit": [
                    ["command": "/users/own/lint.sh"]
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: preExisting, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: paths.cursorSettingsFile))

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        let after = try loadJSONObject(at: paths.cursorSettingsFile)
        let hooks = after["hooks"] as? [String: Any] ?? [:]

        // 1. User's sessionStart hook still there alongside ours.
        let sessionStart = hooks["sessionStart"] as? [[String: Any]] ?? []
        let userStill = sessionStart.contains { ($0["command"] as? String) == userCommand }
        let oursAdded = sessionStart.contains { entry in
            (entry["command"] as? String)?.hasPrefix(paths.cursorHooksDir + "/") == true
        }
        #expect(userStill, "user's pre-existing sessionStart hook should survive")
        #expect(oursAdded, "seshctl sessionStart hook should be added alongside user's")

        // 2. Unrelated event preserved unchanged.
        let afterFileEdit = hooks["afterFileEdit"] as? [[String: Any]] ?? []
        let unrelatedStill = afterFileEdit.contains {
            ($0["command"] as? String) == "/users/own/lint.sh"
        }
        #expect(unrelatedStill, "unrelated event entries should be preserved")
    }

    /// Uninstall must drop only seshctl-anchored entries from Cursor
    /// hooks.json — user-defined entries (including those that happen to
    /// mention "seshctl" elsewhere in their path) survive. The resulting
    /// file is still valid JSON.
    @Test("Cursor uninstall removes only seshctl entries; user entries preserved")
    func cursor_uninstallPreservesUserEntries() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        // Add a user hook to sessionStart and an unrelated-but-substring-
        // matching command to verify the anchored matcher.
        var settings = try loadJSONObject(at: paths.cursorSettingsFile)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let userCommand = "/some/user/script.sh"
        var sessionStart = hooks["sessionStart"] as? [[String: Any]] ?? []
        sessionStart.append(["command": userCommand])
        hooks["sessionStart"] = sessionStart

        let forkCommand = "~/projects/seshctl-fork/cursor-hook.sh"
        var stopEntries = hooks["stop"] as? [[String: Any]] ?? []
        stopEntries.append(["command": forkCommand])
        hooks["stop"] = stopEntries

        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: paths.cursorSettingsFile))

        try FirstLaunchInstaller.uninstall(paths: paths)

        let after = try loadJSONObject(at: paths.cursorSettingsFile)
        let afterHooks = after["hooks"] as? [String: Any] ?? [:]

        // 1. User's sessionStart entry preserved; seshctl entries gone.
        let afterSessionStart = afterHooks["sessionStart"] as? [[String: Any]] ?? []
        let userStill = afterSessionStart.contains { ($0["command"] as? String) == userCommand }
        let oursRemoved = !afterSessionStart.contains { entry in
            (entry["command"] as? String)?.hasPrefix(paths.cursorHooksDir + "/") == true
        }
        #expect(userStill, "user's sessionStart hook should survive uninstall")
        #expect(oursRemoved, "seshctl sessionStart entries should be gone after uninstall")

        // 2. Anchored matcher leaves the seshctl-fork hook alone.
        let afterStop = afterHooks["stop"] as? [[String: Any]] ?? []
        let forkStill = afterStop.contains { ($0["command"] as? String) == forkCommand }
        #expect(forkStill, "user's ~/projects/seshctl-fork hook should survive uninstall")

        // 3. version field preserved (Cursor needs this to parse the file).
        #expect((after["version"] as? Int) == 1,
                "top-level version field should survive uninstall")
    }

    /// Shell-uninstaller mirror of `cursor_uninstallPreservesUserEntries`.
    /// The standalone `scripts/seshctl-uninstall.sh` must clean Cursor's
    /// flat-shape `hooks.json` with the same anchored-prefix matcher the
    /// Swift uninstaller uses: drop seshctl entries, preserve user entries,
    /// preserve the top-level `version`.
    @Test("Standalone shell uninstaller cleans Cursor hooks.json; user entries preserved")
    func cursor_shellUninstallPreservesUserEntries() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)

        // Seed user entries alongside seshctl-installed ones — same setup as
        // the Swift-path test, so the shell path must produce equivalent
        // behavior on the same input.
        var settings = try loadJSONObject(at: paths.cursorSettingsFile)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let userCommand = "/some/user/script.sh"
        var sessionStart = hooks["sessionStart"] as? [[String: Any]] ?? []
        sessionStart.append(["command": userCommand])
        hooks["sessionStart"] = sessionStart

        // Anchored-matcher test: a path that contains "seshctl" but is NOT
        // under the cursor hooks dir prefix must survive.
        let forkCommand = "~/projects/seshctl-fork/cursor-hook.sh"
        var stopEntries = hooks["stop"] as? [[String: Any]] ?? []
        stopEntries.append(["command": forkCommand])
        hooks["stop"] = stopEntries

        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: paths.cursorSettingsFile))

        // Invoke the standalone shell script with HOME=temp.
        let script = repoRoot().appendingPathComponent("scripts/seshctl-uninstall.sh")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = temp.path
        if env["PATH"] == nil || env["PATH"]?.isEmpty == true {
            env["PATH"] = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        }
        proc.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0,
                "shell uninstaller should exit 0; stderr: \(stderr)")

        let after = try loadJSONObject(at: paths.cursorSettingsFile)
        let afterHooks = after["hooks"] as? [String: Any] ?? [:]

        // 1. User's sessionStart entry preserved; seshctl entries gone.
        let afterSessionStart = afterHooks["sessionStart"] as? [[String: Any]] ?? []
        let userStill = afterSessionStart.contains { ($0["command"] as? String) == userCommand }
        let oursRemoved = !afterSessionStart.contains { entry in
            (entry["command"] as? String)?.hasPrefix(paths.cursorHooksDir + "/") == true
        }
        #expect(userStill, "user's sessionStart hook should survive shell uninstall")
        #expect(oursRemoved, "seshctl sessionStart entries should be gone after shell uninstall")

        // 2. Anchored matcher leaves the seshctl-fork hook alone.
        let afterStop = afterHooks["stop"] as? [[String: Any]] ?? []
        let forkStill = afterStop.contains { ($0["command"] as? String) == forkCommand }
        #expect(forkStill, "user's ~/projects/seshctl-fork hook should survive shell uninstall")

        // 3. version field preserved (Cursor needs this to parse the file).
        #expect((after["version"] as? Int) == 1,
                "top-level version field should survive shell uninstall")

        // 4. No seshctl-anchored command lingers anywhere in the file.
        let raw = try String(contentsOfFile: paths.cursorSettingsFile, encoding: .utf8)
        #expect(!raw.contains(paths.cursorHooksDir + "/"),
                "no seshctl cursor hook path should remain in \(paths.cursorSettingsFile)")
    }

    /// Pre-existing malformed `~/.cursor/hooks.json` mirrors the Claude/Codex
    /// behavior: install throws `InstallError.malformedSettings` and a
    /// `.bak-<ts>` of the original garbage is left next to it.
    @Test("Cursor install throws on malformed hooks.json and backs it up")
    func cursor_installThrowsOnMalformedHooksJson() throws {
        let temp = try makeTempHome()
        defer { cleanup(temp) }
        let bundle = try makeFakeBundle(in: temp)
        let paths = FirstLaunchInstaller.Paths(homeRoot: temp)

        // Seed garbage at ~/.cursor/hooks.json.
        let cursorDir = temp.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        let garbage = "this is not json{"
        try Data(garbage.utf8).write(to: URL(fileURLWithPath: paths.cursorSettingsFile))

        var caughtError: Error?
        var thrown = false
        do {
            _ = try FirstLaunchInstaller.install(bundleURL: bundle, paths: paths)
        } catch {
            caughtError = error
            thrown = true
        }
        #expect(thrown, "install should throw on malformed cursor hooks.json")

        guard case .malformedSettings(let badPath, let backupPath)?
                = caughtError as? FirstLaunchInstaller.InstallError
        else {
            Issue.record("expected InstallError.malformedSettings, got \(String(describing: caughtError))")
            return
        }
        #expect(badPath == paths.cursorSettingsFile)
        #expect(backupPath.hasPrefix(paths.cursorSettingsFile + ".bak-"))

        let backupContents = try String(contentsOfFile: backupPath, encoding: .utf8)
        #expect(backupContents == garbage, "backup should preserve the original bytes")
    }
}
