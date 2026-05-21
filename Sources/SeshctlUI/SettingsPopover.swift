import SwiftUI

import SeshctlCore

/// Content view rendered inside the settings popover anchored to the gear
/// button in the panel header. Observes a `ClaudeCodeConnectionStore` and
/// renders a state-dependent Claude Code section plus a static About section.
///
/// Presented via `.popover(isPresented:)` in `SessionListView`; no NSPopover
/// wiring is needed at this layer.
public struct SettingsPopover: View {
    @ObservedObject var store: ClaudeCodeConnectionStore
    @State private var showingConfirmDisconnect = false
    @AppStorage(AppearanceDefaults.repoAccentBarKey) private var repoAccentBarEnabled: Bool = AppearanceDefaults.repoAccentBarDefault
    @AppStorage(AppearanceDefaults.showStatusBarIconKey) private var showStatusBarIcon: Bool = AppearanceDefaults.showStatusBarIconDefault

    /// Optional callbacks for the bottom-of-popover Application section.
    /// Supplied by `AppDelegate` so the popover can offer the same uninstall
    /// flow as the menu bar item and a plain Quit action. When either is nil
    /// the section is hidden entirely (keeps SwiftUI previews and tests that
    /// construct `SettingsPopover(store:)` clean).
    private let onUninstall: (() -> Void)?
    private let onQuit: (() -> Void)?
    private let onOpenIntegrations: (() -> Void)?
    /// Optional callback for the About section's "Check for Updates…" button.
    /// Supplied by `AppDelegate` which routes it to Sparkle's
    /// `SPUStandardUpdaterController.checkForUpdates(_:)`. nil hides the
    /// button (previews/tests).
    private let onCheckForUpdates: (() -> Void)?

    public init(
        store: ClaudeCodeConnectionStore,
        onUninstall: (() -> Void)? = nil,
        onQuit: (() -> Void)? = nil,
        onOpenIntegrations: (() -> Void)? = nil,
        onCheckForUpdates: (() -> Void)? = nil
    ) {
        self.store = store
        self.onUninstall = onUninstall
        self.onQuit = onQuit
        self.onOpenIntegrations = onOpenIntegrations
        self.onCheckForUpdates = onCheckForUpdates
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- Claude Code section ---
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Code (claude.ai)")
                    .font(.system(.headline))

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 8, height: 8)
                    Text(statusLabel)
                        .font(.body)
                }

                Text(statusSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                buttonRow

                if showingConfirmDisconnect {
                    confirmationRow
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            // --- Appearance section ---
            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance")
                    .font(.system(.headline))
                Toggle("Repo color coding", isOn: $repoAccentBarEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text("Tints a vertical bar, the worktree label, and the branch name so sessions from the same repo cluster visually across the list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            // --- About section ---
            VStack(alignment: .leading, spacing: 6) {
                Text("About")
                    .font(.system(.headline))
                Text("seshctl \(Self.appVersionString)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let onCheckForUpdates {
                    HStack {
                        Button("Check for Updates…") { onCheckForUpdates() }
                            .controlSize(.small)
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            // --- Editor Integrations section ---
            // Sits between About and Application so actionable settings cluster
            // together while the destructive Uninstall/Quit row stays at the
            // very bottom. Hidden when AppDelegate doesn't provide a callback
            // (previews/tests).
            if let onOpenIntegrations {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Editor Integrations")
                        .font(.system(.headline))
                    Text("Install the Seshctl companion extension into your editors. Detected editors get terminal-tab focus and (Cursor) chat focus.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Configure…") {
                            onOpenIntegrations()
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            // --- Application section ---
            // Rendered only when AppDelegate has supplied both callbacks.
            // Placed at the bottom (less prominent than Claude Code, which
            // is the primary purpose of this popover) and separated by a
            // divider. The status bar menu offers the same actions; this
            // section is purely additive for users who reach the popover
            // first.
            if onUninstall != nil && onQuit != nil {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Application")
                        .font(.system(.headline))
                    Toggle("Show menu bar icon", isOn: $showStatusBarIcon)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text("Once hidden, you can bring the icon back from this menu.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Uninstall…") { onUninstall?() }
                        Button("Quit") { onQuit?() }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 320)
    }

    // MARK: - Status dot

    private var statusDotColor: Color {
        switch store.state {
        case .connected:
            return .green
        case .authExpired:
            return .orange
        case .transientError:
            return .red
        case .notConnected, .connecting:
            return .gray
        }
    }

    private var statusLabel: String {
        switch store.state {
        case .notConnected:
            return "Not connected"
        case .connecting:
            return "Signing in…"
        case .connected:
            return "Connected"
        case .authExpired:
            return "Sign-in expired"
        case .transientError:
            return "Connected"
        }
    }

    private var statusSubtitle: String {
        switch store.state {
        case .notConnected:
            return "Connect to list your cloud Claude Code sessions here."
        case .connecting:
            return "Complete sign-in in the window that opened."
        case .connected(let lastFetchAt):
            if let date = lastFetchAt {
                return "Last fetch: \(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))"
            }
            return "Waiting for first fetch…"
        case .authExpired:
            return "Cached sessions showing stale data."
        case .transientError(let message):
            return "Last fetch failed: \(message)"
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttonRow: some View {
        HStack(spacing: 8) {
            switch store.state {
            case .notConnected:
                Button("Connect…") { store.presentSignIn() }

            case .connecting:
                Button("Signing in…") {}
                    .disabled(true)

            case .connected:
                Button("Reconnect") { store.presentSignIn() }
                Button("Disconnect") { showingConfirmDisconnect = true }

            case .authExpired:
                Button("Reconnect") { store.presentSignIn() }
                Button("Disconnect") { showingConfirmDisconnect = true }

            case .transientError:
                Button("Retry") {
                    Task { await store.fetchNow() }
                }
                Button("Reconnect") { store.presentSignIn() }
                Button("Disconnect") { showingConfirmDisconnect = true }
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var confirmationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Disconnect? Cached cloud sessions will be cleared.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Cancel") { showingConfirmDisconnect = false }
                Button("Confirm") {
                    showingConfirmDisconnect = false
                    Task { await store.disconnect() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(.top, 4)
    }

    // MARK: - Formatters / constants

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// The app version is read from `CFBundleShortVersionString`. For dev
    /// builds (e.g. running via `swift run` or test harness) the info dict may
    /// not carry the key, so fall back to a stable placeholder.
    static var appVersionString: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty {
            return "v\(version)"
        }
        return "dev"
    }
}
