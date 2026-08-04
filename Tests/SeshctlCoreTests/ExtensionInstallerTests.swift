import Foundation
import Testing

@testable import SeshctlCore

// MARK: - Mocks

final class MockRunner: ExtensionRunner, @unchecked Sendable {
    struct Invocation: Equatable {
        let path: String
        let args: [String]
        let timeout: TimeInterval
    }

    /// First-match-wins. Match an invocation when `path` has the given suffix AND
    /// all `argsContains` substrings are found in the joined args string.
    /// Response: ShellRunner.Result on hit, nil on miss (= simulating launch failure).
    struct Stub {
        var pathSuffix: String
        var argsContains: [String]
        var response: ShellRunner.Result?
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []
    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return _invocations
    }

    var stubs: [Stub] = []

    func run(path: String, args: [String], timeout: TimeInterval) -> ShellRunner.Result? {
        lock.lock()
        _invocations.append(Invocation(path: path, args: args, timeout: timeout))
        lock.unlock()
        let joined = args.joined(separator: " ")
        for stub in stubs {
            if path.hasSuffix(stub.pathSuffix)
                && stub.argsContains.allSatisfy({ joined.contains($0) }) {
                return stub.response
            }
        }
        return nil
    }
}

final class MockAppLocator: AppLocator, @unchecked Sendable {
    var urls: [String: URL] = [:]  // bundleId -> URL
    func appURL(forBundleId bundleId: String) -> URL? { urls[bundleId] }
}

// MARK: - Helpers

/// Build a fake .app at `parent` for the given bundle id, with a stub CLI
/// binary at Contents/Resources/app/bin/<cliName>. Returns the .app URL.
private func makeFakeEditorApp(
    in parent: URL,
    name: String,
    cliName: String?
) throws -> URL {
    let app = parent.appendingPathComponent("\(name).app")
    let bin = app.appendingPathComponent("Contents/Resources/app/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    if let cliName {
        let cli = bin.appendingPathComponent(cliName)
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: cli.path
        )
    }
    return app
}

/// Build a fake Seshctl.app bundle with Contents/Resources/extensions/seshctl.vsix
/// and seshctl.vsix.version. Returns the .app URL.
private func makeFakeSeshctlBundle(
    in parent: URL,
    vsixVersion: String?,
    includeVsix: Bool = true
) throws -> URL {
    let app = parent.appendingPathComponent("Seshctl.app")
    let extDir = app.appendingPathComponent("Contents/Resources/extensions")
    try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
    if includeVsix {
        try Data("FAKE-VSIX-CONTENTS".utf8)
            .write(to: extDir.appendingPathComponent("seshctl.vsix"))
    }
    if let v = vsixVersion {
        try Data(v.utf8)
            .write(to: extDir.appendingPathComponent("seshctl.vsix.version"))
    }
    return app
}

private func makeTempDir() throws -> URL {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("seshctl-ext-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    return temp
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Tests

@Suite("ExtensionInstaller")
struct ExtensionInstallerTests {

    @Test("survey returns empty when no editors are installed")
    func testSurvey_returnsEmptyWhenNoEditorsInstalled() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.2.1")
        let runner = MockRunner()
        let locator = MockAppLocator()  // all bundle ids unresolved
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        let result = installer.surveyInstalledEditors(bundleURL: bundle)
        #expect(result.isEmpty)
    }

    @Test("survey parses installed version")
    func testSurvey_parsesInstalledVersion() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.2.1")
        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )

        let runner = MockRunner()
        runner.stubs = [
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "julo15.seshctl@0.2.1\nother.ext@1.0.0",
                    stderr: "",
                    status: 0
                )
            )
        ]
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        let result = installer.surveyInstalledEditors(bundleURL: bundle)
        #expect(result.count == 1)
        #expect(result.first?.app == .vscode)
        #expect(result.first?.status == .installed(version: "0.2.1"))
    }

    @Test("survey detects outdated when bundled differs from installed")
    func testSurvey_detectsOutdated() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.3.0")
        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )

        let runner = MockRunner()
        runner.stubs = [
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "julo15.seshctl@0.2.1\nother.ext@1.0.0",
                    stderr: "",
                    status: 0
                )
            )
        ]
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        let result = installer.surveyInstalledEditors(bundleURL: bundle)
        #expect(result.count == 1)
        #expect(result.first?.status == .outdated(installed: "0.2.1", bundled: "0.3.0"))
    }

    @Test("survey marks missing extension as notInstalled")
    func testSurvey_handlesMissingExtension() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.2.1")
        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )

        let runner = MockRunner()
        runner.stubs = [
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "other.ext@1.0.0",
                    stderr: "",
                    status: 0
                )
            )
        ]
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        let result = installer.surveyInstalledEditors(bundleURL: bundle)
        #expect(result.count == 1)
        #expect(result.first?.status == .notInstalled)
    }

    @Test("survey handles malformed CLI output")
    func testSurvey_handlesMalformedOutput() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.2.1")
        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )

        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp

        for output in ["", "@@@---broken", "\n"] {
            let runner = MockRunner()
            runner.stubs = [
                .init(
                    pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                    argsContains: ["--list-extensions"],
                    response: ShellRunner.Result(stdout: output, stderr: "", status: 0)
                )
            ]
            let installer = ExtensionInstaller(runner: runner, appLocator: locator)
            let result = installer.surveyInstalledEditors(bundleURL: bundle)
            #expect(result.count == 1)
            #expect(result.first?.status == .notInstalled, "output=\(output.debugDescription)")
        }
    }

    @Test("survey returns cliUnavailable when CLI binary is missing")
    func testSurvey_returnsCLIUnavailableWhenCLIMissing() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.2.1")
        // App exists but no CLI binary inside.
        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: nil
        )

        // Runner has no stubs → /usr/bin/which returns nil (launch-fail simulation).
        let runner = MockRunner()
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        let result = installer.surveyInstalledEditors(bundleURL: bundle)
        #expect(result.count == 1)
        #expect(result.first?.app == .vscode)
        #expect(result.first?.status == .cliUnavailable)
    }

    @Test("install invokes the VS Code CLI with the bundled vsix")
    func testInstall_invokesCorrectCLIForVSCode() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.2.1")
        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )

        let runner = MockRunner()
        runner.stubs = [
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--install-extension"],
                response: ShellRunner.Result(stdout: "", stderr: "", status: 0)
            ),
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "julo15.seshctl@0.2.1",
                    stderr: "",
                    status: 0
                )
            ),
        ]
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        let status = try installer.install(editor: .vscode, bundleURL: bundle)
        #expect(status == .installed(version: "0.2.1"))

        let installInvocation = runner.invocations.first { inv in
            inv.path.hasSuffix("Visual Studio Code.app/Contents/Resources/app/bin/code")
                && inv.args.contains("--install-extension")
        }
        #expect(installInvocation != nil)
        let vsixPath = bundle.appendingPathComponent(
            "Contents/Resources/extensions/seshctl.vsix"
        ).path
        #expect(installInvocation?.args.contains(vsixPath) == true)
        #expect(installInvocation?.args.contains("--force") == true)
    }

    @Test("install invokes the Cursor CLI")
    func testInstall_invokesCursorCLI() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.2.1")
        let cursorApp = try makeFakeEditorApp(
            in: temp,
            name: "Cursor",
            cliName: "cursor"
        )

        let runner = MockRunner()
        runner.stubs = [
            .init(
                pathSuffix: "Cursor.app/Contents/Resources/app/bin/cursor",
                argsContains: ["--install-extension"],
                response: ShellRunner.Result(stdout: "", stderr: "", status: 0)
            ),
            .init(
                pathSuffix: "Cursor.app/Contents/Resources/app/bin/cursor",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "julo15.seshctl@0.2.1",
                    stderr: "",
                    status: 0
                )
            ),
        ]
        let locator = MockAppLocator()
        locator.urls[TerminalApp.cursor.bundleId] = cursorApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        _ = try installer.install(editor: .cursor, bundleURL: bundle)

        let installInvocation = runner.invocations.first { inv in
            inv.path.hasSuffix("Cursor.app/Contents/Resources/app/bin/cursor")
                && inv.args.contains("--install-extension")
        }
        #expect(installInvocation != nil)
    }

    @Test("install captures stderr on subprocess failure")
    func testInstall_capturesStderrOnFailure() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.2.1")
        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )

        let runner = MockRunner()
        runner.stubs = [
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--install-extension"],
                response: ShellRunner.Result(
                    stdout: "",
                    stderr: "permission denied",
                    status: 1
                )
            )
        ]
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        #expect(
            throws: InstallError.subprocessFailed(stderr: "permission denied", status: 1)
        ) {
            try installer.install(editor: .vscode, bundleURL: bundle)
        }
    }

    @Test("install throws bundledVsixMissing when vsix file is absent")
    func testInstall_throwsBundledVsixMissingWhenSidecarPresentButFileMissing() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(
            in: temp,
            vsixVersion: "0.2.1",
            includeVsix: false
        )
        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )

        let runner = MockRunner()
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        #expect(throws: InstallError.bundledVsixMissing) {
            try installer.install(editor: .vscode, bundleURL: bundle)
        }
    }

    @Test("install throws cliNotFound when editor app is missing")
    func testInstall_throwsCliNotFoundWhenAppMissing() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.2.1")
        let runner = MockRunner()
        let locator = MockAppLocator()  // no urls registered
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        #expect(throws: InstallError.cliNotFound) {
            try installer.install(editor: .vscode, bundleURL: bundle)
        }
    }

    @Test("refresh skips editors without the extension installed")
    func testRefresh_skipsEditorsWithoutExtensionInstalled() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.3.0")
        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )

        let runner = MockRunner()
        runner.stubs = [
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "other.ext@1.0.0",
                    stderr: "",
                    status: 0
                )
            )
        ]
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        let logs = installer.refreshExistingInstalls(bundleURL: bundle)
        #expect(logs.isEmpty)

        let installInvocations = runner.invocations.filter {
            $0.args.contains("--install-extension")
        }
        #expect(installInvocations.isEmpty)
    }

    @Test("refresh skips editors that are already up to date")
    func testRefresh_skipsUpToDateEditors() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.2.1")
        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )

        let runner = MockRunner()
        runner.stubs = [
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "julo15.seshctl@0.2.1",
                    stderr: "",
                    status: 0
                )
            )
        ]
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        let logs = installer.refreshExistingInstalls(bundleURL: bundle)
        #expect(logs.isEmpty)

        let installInvocations = runner.invocations.filter {
            $0.args.contains("--install-extension")
        }
        #expect(installInvocations.isEmpty)
    }

    @Test("refresh reinstalls outdated editors")
    func testRefresh_reinstallsOutdated() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.3.0")
        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )

        let runner = MockRunner()
        runner.stubs = [
            // Survey query AND post-install re-query both hit this stub.
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "julo15.seshctl@0.2.1",
                    stderr: "",
                    status: 0
                )
            ),
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--install-extension"],
                response: ShellRunner.Result(stdout: "", stderr: "", status: 0)
            ),
        ]
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        let logs = installer.refreshExistingInstalls(bundleURL: bundle)
        #expect(logs.count == 1)
        #expect(logs.first?.contains("0.2.1 -> 0.3.0") == true)

        let installInvocations = runner.invocations.filter {
            $0.args.contains("--install-extension")
        }
        #expect(installInvocations.count == 1)
    }

    @Test("uninstallAll skips editors without the extension installed")
    func testUninstallAll_skipsEditorsWithoutExtensionInstalled() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )

        let runner = MockRunner()
        runner.stubs = [
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "other.ext@1.0.0",
                    stderr: "",
                    status: 0
                )
            )
        ]
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        let logs = installer.uninstallAllEditorExtensions()
        #expect(logs.isEmpty)

        let uninstallInvocations = runner.invocations.filter {
            $0.args.contains("--uninstall-extension")
        }
        #expect(uninstallInvocations.isEmpty)
    }

    @Test("uninstallAll uninstalls editors that have the extension")
    func testUninstallAll_uninstallsInstalledEditors() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )
        let cursorApp = try makeFakeEditorApp(
            in: temp,
            name: "Cursor",
            cliName: "cursor"
        )

        let runner = MockRunner()
        runner.stubs = [
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "julo15.seshctl@0.2.1",
                    stderr: "",
                    status: 0
                )
            ),
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--uninstall-extension"],
                response: ShellRunner.Result(stdout: "", stderr: "", status: 0)
            ),
            .init(
                pathSuffix: "Cursor.app/Contents/Resources/app/bin/cursor",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "julo15.seshctl@0.3.0",
                    stderr: "",
                    status: 0
                )
            ),
            .init(
                pathSuffix: "Cursor.app/Contents/Resources/app/bin/cursor",
                argsContains: ["--uninstall-extension"],
                response: ShellRunner.Result(stdout: "", stderr: "", status: 0)
            ),
        ]
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        locator.urls[TerminalApp.cursor.bundleId] = cursorApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        let logs = installer.uninstallAllEditorExtensions()
        #expect(logs.count == 2)
        #expect(logs.contains(where: { $0.contains("VS Code") && $0.contains("0.2.1") && $0.contains("success") }))
        #expect(logs.contains(where: { $0.contains("Cursor") && $0.contains("0.3.0") && $0.contains("success") }))

        let uninstallInvocations = runner.invocations.filter {
            $0.args.contains("--uninstall-extension")
        }
        #expect(uninstallInvocations.count == 2)
        // Confirms the extension id is what's passed to --uninstall-extension.
        #expect(uninstallInvocations.allSatisfy { $0.args.contains("julo15.seshctl") })
    }

    @Test("uninstallAll logs failure when subprocess returns nonzero")
    func testUninstallAll_logsFailureOnSubprocessError() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )

        let runner = MockRunner()
        runner.stubs = [
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "julo15.seshctl@0.2.1",
                    stderr: "",
                    status: 0
                )
            ),
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--uninstall-extension"],
                response: ShellRunner.Result(
                    stdout: "",
                    stderr: "permission denied",
                    status: 1
                )
            ),
        ]
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        let logs = installer.uninstallAllEditorExtensions()
        #expect(logs.count == 1)
        let line = try #require(logs.first)
        #expect(line.contains("FAILED"))
        #expect(line.contains("permission denied"))
    }

    @Test("uninstallAll treats 'not installed' stderr as success (idempotent)")
    func testUninstallAll_idempotentNotInstalled() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let vscodeApp = try makeFakeEditorApp(
            in: temp,
            name: "Visual Studio Code",
            cliName: "code"
        )

        let runner = MockRunner()
        runner.stubs = [
            // List shows it installed so we enter the uninstall path...
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "julo15.seshctl@0.2.1",
                    stderr: "",
                    status: 0
                )
            ),
            // ...but the uninstall races and the CLI says "not installed".
            // ExtensionInstaller.uninstall(editor:) treats this as success.
            .init(
                pathSuffix: "Visual Studio Code.app/Contents/Resources/app/bin/code",
                argsContains: ["--uninstall-extension"],
                response: ShellRunner.Result(
                    stdout: "",
                    stderr: "Extension 'julo15.seshctl' is not installed.",
                    status: 1
                )
            ),
        ]
        let locator = MockAppLocator()
        locator.urls[TerminalApp.vscode.bundleId] = vscodeApp
        let installer = ExtensionInstaller(runner: runner, appLocator: locator)

        let logs = installer.uninstallAllEditorExtensions()
        #expect(logs.count == 1)
        #expect(logs.first?.contains("success") == true)
    }

    @Test("bundledVersion reads and trims the sidecar")
    func testBundledVersion_readsFromSidecar() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "0.4.2\n")
        let installer = ExtensionInstaller(
            runner: MockRunner(),
            appLocator: MockAppLocator()
        )

        #expect(installer.bundledVersion(bundleURL: bundle) == "0.4.2")
    }

    @Test("bundledVersion returns nil when sidecar is missing")
    func testBundledVersion_returnsNilWhenSidecarMissing() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: nil)
        let installer = ExtensionInstaller(
            runner: MockRunner(),
            appLocator: MockAppLocator()
        )

        #expect(installer.bundledVersion(bundleURL: bundle) == nil)
    }

    @Test("bundledVersion returns nil for an empty sidecar")
    func testBundledVersion_returnsNilWhenSidecarEmpty() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let bundle = try makeFakeSeshctlBundle(in: temp, vsixVersion: "")
        let installer = ExtensionInstaller(
            runner: MockRunner(),
            appLocator: MockAppLocator()
        )

        // Empty content trims to empty string → implementation maps that to nil.
        #expect(installer.bundledVersion(bundleURL: bundle) == nil)
    }

    @Test("TerminalApp.extensionCLIName maps editors and returns nil for terminals")
    func testTerminalApp_extensionCLIName() {
        for app in TerminalApp.allCases {
            switch app {
            case .vscode:
                #expect(app.extensionCLIName == "code")
            case .vscodeInsiders:
                #expect(app.extensionCLIName == "code-insiders")
            case .cursor:
                #expect(app.extensionCLIName == "cursor")
            case .terminal, .iterm2, .warp, .ghostty, .cmux:
                #expect(app.extensionCLIName == nil)
            }
        }
    }

    @Test("parseInstalledVersion requires exact id match, not substring")
    func testParseInstalledVersion_exactPrefixMatch() {
        #expect(
            ExtensionInstaller.parseInstalledVersion(output: "julo15.seshctl@0.2.1") == "0.2.1"
        )
        #expect(
            ExtensionInstaller.parseInstalledVersion(output: "prefixjulo15.seshctl@9.9.9") == nil
        )
        #expect(
            ExtensionInstaller.parseInstalledVersion(output: "julo15.seshctl-stable@1.0.0") == nil
        )
    }
}

// MARK: - CanonicalPathsAppLocator
//
// Foundation-only AppLocator used by CLI contexts. Hard-coded bundle-id →
// /Applications/<name>.app mapping; existence-checked via FileManager.

@Suite("CanonicalPathsAppLocator")
struct CanonicalPathsAppLocatorTests {

    @Test("returns URL when canonical .app exists at applications root")
    func testReturnsURLWhenAppExists() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        // Mirror /Applications layout: drop a Cursor.app directory inside.
        try FileManager.default.createDirectory(
            at: temp.appendingPathComponent("Cursor.app"),
            withIntermediateDirectories: true
        )

        let locator = CanonicalPathsAppLocator(applicationsRoot: temp)
        let resolved = locator.appURL(forBundleId: TerminalApp.cursor.bundleId)
        #expect(resolved?.lastPathComponent == "Cursor.app")
    }

    @Test("returns nil when canonical .app is absent")
    func testReturnsNilWhenAppMissing() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        let locator = CanonicalPathsAppLocator(applicationsRoot: temp)
        #expect(locator.appURL(forBundleId: TerminalApp.vscode.bundleId) == nil)
    }

    @Test("returns nil for unknown / non-editor bundle IDs")
    func testReturnsNilForUnknownBundleId() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        // Even if a directory with that name happens to exist, an unknown
        // bundle ID has no canonical mapping → nil.
        try FileManager.default.createDirectory(
            at: temp.appendingPathComponent("Terminal.app"),
            withIntermediateDirectories: true
        )

        let locator = CanonicalPathsAppLocator(applicationsRoot: temp)
        #expect(locator.appURL(forBundleId: "com.apple.Terminal") == nil)
        #expect(locator.appURL(forBundleId: TerminalApp.iterm2.bundleId) == nil)
    }

    @Test("maps each supported editor bundle ID to the expected filename")
    func testCanonicalFilenameMapping() {
        #expect(
            CanonicalPathsAppLocator.canonicalAppFilename(forBundleId: TerminalApp.vscode.bundleId)
                == "Visual Studio Code.app"
        )
        #expect(
            CanonicalPathsAppLocator.canonicalAppFilename(forBundleId: TerminalApp.vscodeInsiders.bundleId)
                == "Visual Studio Code - Insiders.app"
        )
        #expect(
            CanonicalPathsAppLocator.canonicalAppFilename(forBundleId: TerminalApp.cursor.bundleId)
                == "Cursor.app"
        )
    }

    @Test("integration: CanonicalPathsAppLocator + ExtensionInstaller end-to-end (CLI uninstall path)")
    func testCanonicalPathsIntegration_uninstallWiring() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        // Mirror /Applications: drop a Cursor.app at exactly the canonical
        // name that CanonicalPathsAppLocator expects.
        let cursorApp = try makeFakeEditorApp(
            in: temp,
            name: "Cursor",
            cliName: "cursor"
        )
        #expect(cursorApp.lastPathComponent == "Cursor.app")

        let runner = MockRunner()
        runner.stubs = [
            .init(
                pathSuffix: "Cursor.app/Contents/Resources/app/bin/cursor",
                argsContains: ["--list-extensions"],
                response: ShellRunner.Result(
                    stdout: "julo15.seshctl@0.2.1",
                    stderr: "",
                    status: 0
                )
            ),
            .init(
                pathSuffix: "Cursor.app/Contents/Resources/app/bin/cursor",
                argsContains: ["--uninstall-extension"],
                response: ShellRunner.Result(stdout: "", stderr: "", status: 0)
            ),
        ]

        // The exact shape the CLI's Uninstall.run() builds — real
        // CanonicalPathsAppLocator with a test-rooted applicationsRoot.
        let installer = ExtensionInstaller(
            runner: runner,
            appLocator: CanonicalPathsAppLocator(applicationsRoot: temp)
        )

        let logs = installer.uninstallAllEditorExtensions()
        #expect(logs.count == 1)
        #expect(logs.first?.contains("Cursor") == true)
        #expect(logs.first?.contains("success") == true)

        // Confirms the locator resolved the canonical /Applications/Cursor.app
        // path AND that ExtensionInstaller then descended to the in-bundle CLI.
        let uninstallInvocations = runner.invocations.filter {
            $0.args.contains("--uninstall-extension") && $0.args.contains("julo15.seshctl")
        }
        #expect(uninstallInvocations.count == 1)
        #expect(uninstallInvocations.first?.path.hasSuffix("Cursor.app/Contents/Resources/app/bin/cursor") == true)
    }

    @Test("treats a plain file at the candidate path as missing")
    func testIgnoresPlainFiles() throws {
        let temp = try makeTempDir()
        defer { cleanup(temp) }

        // .app paths are required to be directories. A regular file with the
        // right name should not be treated as a hit.
        try Data("not an app".utf8)
            .write(to: temp.appendingPathComponent("Cursor.app"))

        let locator = CanonicalPathsAppLocator(applicationsRoot: temp)
        #expect(locator.appURL(forBundleId: TerminalApp.cursor.bundleId) == nil)
    }
}

// MARK: - ShellRunner integration tests
//
// These exercise the real subprocess path against well-known system binaries.
// They are intentionally minimal — just enough to cover launch/exit/timeout
// branches that the mocked ExtensionInstaller tests bypass.

@Suite("ShellRunner")
struct ShellRunnerTests {

    @Test("captures stdout from a successful command")
    func capturesStdout() {
        let result = ShellRunner.run(path: "/bin/echo", args: ["hello", "world"], timeout: 5)
        #expect(result != nil)
        #expect(result?.stdout == "hello world")
        #expect(result?.stderr == "")
        #expect(result?.status == 0)
    }

    @Test("captures stderr and nonzero status")
    func capturesStderrAndNonzeroStatus() {
        // /bin/sh -c 'echo oops >&2; exit 3'
        let result = ShellRunner.run(
            path: "/bin/sh",
            args: ["-c", "echo oops >&2; exit 3"],
            timeout: 5
        )
        #expect(result != nil)
        #expect(result?.stdout == "")
        #expect(result?.stderr == "oops")
        #expect(result?.status == 3)
    }

    @Test("returns nil when executable path does not exist")
    func returnsNilOnLaunchFailure() {
        let result = ShellRunner.run(
            path: "/definitely/not/a/real/binary/path",
            args: [],
            timeout: 5
        )
        #expect(result == nil)
    }

    @Test("returns nil when subprocess exceeds timeout")
    func returnsNilOnTimeout() {
        // sleep 10 with a 0.3s timeout — terminate path.
        let start = Date()
        let result = ShellRunner.run(path: "/bin/sh", args: ["-c", "sleep 10"], timeout: 0.3)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result == nil)
        // Should return well before the full 10s sleep — give generous headroom
        // for slow CI but still much less than the sleep duration.
        #expect(elapsed < 5.0)
    }

    @Test("extra environment reaches the child process")
    func extraEnvironmentIsSet() {
        let result = ShellRunner.run(
            path: "/bin/sh",
            args: ["-c", "printf %s \"$SESHCTL_TEST_MARKER\""],
            timeout: 5,
            extraEnvironment: ["SESHCTL_TEST_MARKER": "on"]
        )
        #expect(result?.stdout == "on")
        #expect(result?.status == 0)
    }

    @Test("extra environment is merged onto the inherited one")
    func inheritedEnvironmentSurvives() {
        // Assigning `process.environment` outright would strip PATH and HOME,
        // which breaks every CLI we launch this way.
        let result = ShellRunner.run(
            path: "/bin/sh",
            args: ["-c", "printf %s \"$HOME\""],
            timeout: 5,
            extraEnvironment: ["SESHCTL_TEST_MARKER": "on"]
        )
        #expect(result?.stdout == NSHomeDirectory())
    }

    @Test("child inherits our environment when nothing extra is passed")
    func defaultEnvironmentUnchanged() {
        let result = ShellRunner.run(
            path: "/bin/sh",
            args: ["-c", "printf %s \"$HOME\""],
            timeout: 5
        )
        #expect(result?.stdout == NSHomeDirectory())
    }
}
