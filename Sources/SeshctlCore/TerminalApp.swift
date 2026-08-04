import Foundation

/// Single source of truth for all known terminal and editor apps.
public enum TerminalApp: String, CaseIterable, Sendable {
    case terminal
    case iterm2
    case warp
    case ghostty
    case cmux
    case vscode
    case vscodeInsiders
    case cursor

    // MARK: - Properties

    public var bundleId: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm2: "com.googlecode.iterm2"
        case .warp: "dev.warp.Warp-Stable"
        case .ghostty: "com.mitchellh.ghostty"
        case .cmux: "com.cmuxterm.app"
        case .vscode: "com.microsoft.VSCode"
        case .vscodeInsiders: "com.microsoft.VSCodeInsiders"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        }
    }

    public var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm2: "iTerm2"
        case .warp: "Warp"
        case .ghostty: "Ghostty"
        case .cmux: "cmux"
        case .vscode: "VS Code"
        case .vscodeInsiders: "VS Code Insiders"
        case .cursor: "Cursor"
        }
    }

    public var uriScheme: String? {
        switch self {
        case .terminal, .iterm2, .warp, .ghostty, .cmux: nil
        case .vscode: "vscode"
        case .vscodeInsiders: "vscode-insiders"
        case .cursor: "cursor"
        }
    }

    /// The CLI binary name used to manage extensions for this editor, found at
    /// `<editor.app>/Contents/Resources/app/bin/<name>`. Returns nil for terminal
    /// apps that don't have a `--install-extension` style CLI.
    public var extensionCLIName: String? {
        switch self {
        case .terminal, .iterm2, .warp, .ghostty, .cmux: nil
        case .vscode: "code"
        case .vscodeInsiders: "code-insiders"
        case .cursor: "cursor"
        }
    }

    // MARK: - Capabilities

    /// Whether this app supports the AppleScript focus path (open -b + AppleScript tab selection).
    /// Terminal.app, iTerm2 and Ghostty match by TTY (Ghostty falls back to working
    /// directory on older versions whose dictionary lacks `tty`); cmux matches by
    /// workspace UUID via its AppleScript `tab` model.
    public var supportsAppleScriptFocus: Bool {
        switch self {
        case .terminal, .iterm2, .ghostty, .warp, .cmux: true
        case .vscode, .vscodeInsiders, .cursor: false
        }
    }

    public var supportsAppleScriptResume: Bool {
        switch self {
        case .terminal, .iterm2, .ghostty, .warp, .cmux: true
        case .vscode, .vscodeInsiders, .cursor: false
        }
    }

    public var supportsURIHandler: Bool {
        switch self {
        case .vscode, .vscodeInsiders, .cursor: true
        case .terminal, .iterm2, .warp, .ghostty, .cmux: false
        }
    }

    // MARK: - Lookup

    public static func from(bundleId: String) -> TerminalApp? {
        allCases.first { $0.bundleId == bundleId }
    }

    /// Match by the TERM_PROGRAM environment variable value.
    public static func from(termProgram: String) -> TerminalApp? {
        let lower = termProgram.lowercased()
        switch lower {
        case "apple_terminal": return .terminal
        case "iterm.app": return .iterm2
        case "warpterm": return .warp
        case "ghostty": return .ghostty
        case "vscode": return .vscode
        default: return nil
        }
    }

    /// Match by the session-start environment. Checks cmux-specific variables
    /// before falling back to `TERM_PROGRAM` so the `TERM_PROGRAM=ghostty`
    /// collision that cmux sets inside its spawned shells resolves to `.cmux`.
    public static func from(environment env: [String: String]) -> TerminalApp? {
        if env["CMUX_WORKSPACE_ID"] != nil || env["CMUX_SOCKET_PATH"] != nil {
            return .cmux
        }
        if let termProgram = env["TERM_PROGRAM"] {
            return from(termProgram: termProgram)
        }
        return nil
    }

    // MARK: - Collections

    public static let allTerminals: [TerminalApp] = [.terminal, .iterm2, .warp, .ghostty, .cmux]

    public static let allVSCodeVariants: [TerminalApp] = [.vscode, .vscodeInsiders, .cursor]

    public static var allBundleIds: [String] {
        allCases.map(\.bundleId)
    }
}
