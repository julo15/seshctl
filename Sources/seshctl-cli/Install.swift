import ArgumentParser
import Foundation
import SeshctlCore

// MARK: - Install
//
// Thin CLI wrappers around `FirstLaunchInstaller` (in `SeshctlCore`). The
// implementation moved out of this file so the GUI app can reuse it from
// `AppDelegate.applicationDidFinishLaunching`.

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install seshctl: hook registrations, CLI symlinks, and bundle-aware marker."
    )

    func run() throws {
        // If the CLI binary lives inside a .app (e.g. invoked via
        // /Applications/Seshctl.app/Contents/MacOS/seshctl-cli, or via the
        // ~/.local/bin/seshctl symlink that resolves into a bundle), walk
        // up from argv[0] to find the enclosing .app and pass it so the
        // installer reads hook templates from the bundle's Resources and
        // points the CLI symlink at the bundled binary. Falls back to the
        // repo-source-tree resolution path when run from `swift run` or
        // `.build/release/seshctl-cli`.
        let bundleURL = detectEnclosingBundle()
        let result = try FirstLaunchInstaller.install(bundleURL: bundleURL)
        for action in result.actions {
            print("  \(describe(action))")
        }
        print("seshctl installed.")
    }
}

// MARK: - Uninstall

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: """
            Remove all seshctl integrations from this Mac. Session history is \
            preserved by default — pass --delete-history to remove the database too.
            """
    )

    @Flag(name: .long, help: "Also delete session history at ~/.local/share/seshctl/seshctl.db")
    var deleteHistory = false

    func run() throws {
        // Best-effort editor-extension cleanup before tearing down our own
        // install state. Mirrors AppDelegate.runUninstallFlow. CLI contexts
        // can't use NSWorkspace, so we use CanonicalPathsAppLocator — it
        // hard-codes the /Applications paths the standalone shell script
        // probes. The PATH fallback inside ExtensionInstaller covers users
        // who relocated the editor. Failures are logged and never thrown.
        let extensionInstaller = ExtensionInstaller(appLocator: CanonicalPathsAppLocator())
        let extensionLogs = extensionInstaller.uninstallAllEditorExtensions()
        for line in extensionLogs {
            print("  \(line)")
        }

        let result = try FirstLaunchInstaller.uninstall(deleteSessionHistory: deleteHistory)
        for action in result.actions {
            print("  \(describe(action))")
        }
        print("seshctl uninstalled.")
    }
}

// MARK: - Bundle detection

/// Walk up from argv[0] looking for an enclosing `.app` directory. Returns
/// the bundle URL when found (e.g. `/Applications/Seshctl.app`), or nil
/// when the CLI is running from a raw build output (`swift run`,
/// `.build/release/seshctl-cli`). The walk follows symlinks, so the
/// `~/.local/bin/seshctl` → bundle symlink resolves correctly too.
private func detectEnclosingBundle() -> URL? {
    var url = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    while url.path != "/" {
        if url.pathExtension == "app" {
            return url
        }
        url = url.deletingLastPathComponent()
    }
    return nil
}

// MARK: - Action description

private func describe(_ action: FirstLaunchInstaller.Action) -> String {
    switch action {
    case .symlinkCreated(let path, let target):
        return "symlink created: \(path) → \(target)"
    case .symlinkReplaced(let path, let target):
        return "symlink updated: \(path) → \(target)"
    case .migratedRealFileToSymlink(let path):
        return "migrated stale file to symlink: \(path)"
    case .uninstallerScriptWritten(let path):
        return "wrote uninstaller: \(path)"
    case .hookScriptWritten(let path):
        return "wrote hook script: \(path)"
    case .hookRegistered(let llm, let event):
        return "\(llm): registered \(event) hook"
    case .hookAlreadyRegistered(let llm, let event):
        return "\(llm): \(event) already registered"
    case .codexConfigUpdated:
        return "set [features].hooks = true in ~/.agents/config.toml"
    case .codexConfigAlreadySet:
        return "[features].hooks = true already set"
    case .codexConfigCleared(let path):
        return "cleared [features].hooks = true from \(path)"
    case .markerFileWritten(let path):
        return "wrote marker file: \(path)"
    case .removedHookEntry(let llm, let event):
        return "\(llm): removed \(event) hook entry"
    case .removedSymlink(let path):
        return "removed symlink: \(path)"
    case .removedFile(let path):
        return "removed file: \(path)"
    case .removedDirectory(let path):
        return "removed directory: \(path)"
    case .noted(let msg):
        return msg
    }
}
