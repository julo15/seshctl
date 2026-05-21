import AppKit
import ApplicationServices
import KeyboardShortcuts
import SeshctlCore
import SeshctlUI
import Sparkle
import SwiftUI

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel", default: .init(.s, modifiers: [.command, .shift]))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var viewModel: SessionListViewModel?
    private var connectionStore: ClaudeCodeConnectionStore?
    private var navigationState = NavigationState()
    private var pendingG = false
    private let remoteBrowserCoordinator = RemoteBrowserCoordinator()

    // Menu-bar status item. Visibility is driven by the
    // `AppearanceDefaults.showStatusBarIconKey` preference (default on); see
    // `reconcileStatusItemVisibility()`. The Show/Hide menu item is held
    // weakly so `menuWillOpen` can update its title to reflect current panel
    // visibility.
    private var statusItem: NSStatusItem?
    private weak var toggleItem: NSMenuItem?

    // Token for the UserDefaults observer that reconciles status item
    // visibility when the toggle in SettingsPopover flips. AppDelegate's
    // lifetime is process-scope so we don't bother removing it on deinit
    // (see the comment near the bottom of the class).
    private var defaultsObserver: NSObjectProtocol?

    // Sparkle's standard updater controller. Drives automatic update checks
    // (on launch + every 24h per `SUEnableAutomaticChecks` in Info.plist) and
    // serves the "Check for Updates…" menu action. Retained for the process
    // lifetime; the controller owns its own background timer.
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // First-launch installer. Only triggered when running from a `.app`
        // bundle (DMG install path). Skipped during `swift run SeshctlApp` and
        // dev-mode `make install` so we don't interfere with the existing dev
        // flow. Runs before the Accessibility prompt so a user who picks
        // "Quit" on the welcome panel doesn't get a second permission dialog
        // on the way out.
        //
        // The return value tells us whether a fresh install just completed
        // *on this launch*. When true we suppress the panel auto-show at the
        // end of this method so the system's Accessibility permission prompt
        // (kicked off asynchronously by `AXIsProcessTrustedWithOptions`
        // below) isn't covered by our `.floating`-level panel. The user can
        // still bring up the panel via the global hotkey or menu bar item
        // whenever they're ready.
        let didJustInstall = runFirstLaunchInstallerIfNeeded()

        // Sparkle auto-updates. SUFeedURL, SUPublicEDKey, and
        // SUEnableAutomaticChecks live in Resources/Info.plist. With
        // startingUpdater: true the controller's background scheduler fires
        // immediately on launch and again every 24h while the app runs;
        // SettingsPopover's "Check for Updates…" button calls
        // updaterController.checkForUpdates(_:) on demand. Pre-Phase-1B we're
        // still self-signed — Sparkle's EdDSA signature is independent of
        // Apple's code signature, so it works without notarization.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Silent refresh of the bundled editor extension — only acts on editors that
        // already have julo15.seshctl installed at a stale version. Background queue
        // so we don't block launch; results go to ~/Library/Logs/Seshctl/install.log.
        refreshEditorExtensionsInBackground()

        // Request Accessibility permission. Needed for `System Events`
        // AXRaise calls in BrowserController (used to bring the matched
        // browser window forward for remote Claude sessions when multiple
        // browser windows are open). macOS shows the system prompt only on
        // the first launch where the app isn't yet trusted; subsequent
        // launches no-op. Missing permission isn't fatal — AXRaise is
        // wrapped in try and degrades to "wrong window stays front".
        //
        // Hardcoded literal instead of `kAXTrustedCheckOptionPrompt` so the
        // call sidesteps Swift 6 strict-concurrency complaints about C
        // globals imported as `var`. The underlying CFString is stable.
        let promptOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(promptOptions)


        // One-shot UserDefaults migration for the repo-color-coding toggle.
        AppearanceDefaults.migrateLegacyKey()

        // Set up database and view model
        do {
            let path = NSString(
                string: "~/.local/share/seshctl/seshctl.db"
            ).expandingTildeInPath
            let db = try SeshctlDatabase(path: path)
            let vm = SessionListViewModel(database: db, defaults: .standard)
            viewModel = vm

            // Claude Code (cloud) connection store. Cookies live in
            // NSHTTPCookieStorage.shared — the sign-in sheet mirrors WebView
            // cookies there because WKWebsiteDataStore does not reliably
            // persist across launches for SwiftPM bare executables.
            let cookieSource = ClosureCookieSource {
                HTTPCookieStorage.shared.cookies ?? []
            }
            let fetcher = RemoteClaudeCodeFetcher(cookieSource: cookieSource, database: db)
            let store = ClaudeCodeConnectionStore(database: db, fetcher: fetcher)
            connectionStore = store
            store.startPeriodicFetching()

            let nav = navigationState

            // Create panel with root view that switches between list and detail
            let rootView = RootView(
                navigationState: nav,
                listViewModel: vm,
                connectionStore: store,
                onSessionTap: { [weak self] session in
                    guard let self, let vm = self.viewModel else { return }
                    let target: SessionActionTarget = session.isActive
                        ? .activeSession(session) : .inactiveSession(session)
                    SessionAction.execute(
                        target: target,
                        markRead: { vm.markSessionRead($0) },
                        rememberFocused: { vm.rememberFocusedSession($0) },
                        dismiss: { self.dismissPanel() },
                        remoteBrowserCoordinator: self.remoteBrowserCoordinator
                    )
                },
                onOpenDetail: { [weak nav] session in
                    nav?.openDetail(for: session)
                },
                onOpenRecallDetail: { [weak nav] result, session in
                    nav?.openDetail(for: result, session: session)
                },
                onUninstall: { [weak self] in self?.runUninstallFlow() },
                onOpenIntegrations: { IntegrationsWindowController.shared.showWindow(nil) },
                onCheckForUpdates: { [weak self] in self?.checkForUpdates() },
                onQuit: { NSApp.terminate(nil) }
            )

            let panelRef = FloatingPanel(rootView: rootView)
            panel = panelRef

            // Keyboard navigation
            panelRef.onKeyDown = { [weak self] keyCode, chars, modifiers in
                self?.handleKey(keyCode: keyCode, chars: chars, modifiers: modifiers)
            }

            // Stop polling when panel is dismissed via click-outside
            panelRef.onDismiss = { [weak self] in
                self?.viewModel?.recordPanelClose()
                self?.viewModel?.panelDidHide()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Seshctl failed to start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Register global hotkey
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.togglePanel()
        }

        // Menu-bar status item. Set up after the panel/database exist so the
        // Show/Hide and Uninstall actions have something to operate on.
        setupStatusItem()
        observeStatusItemPreference()

        // Show panel on launch — but only when we didn't just run the
        // first-launch installer. Right after install macOS asynchronously
        // surfaces the Accessibility permission prompt; our floating panel
        // would otherwise pop up on top of it. The successful install dialog
        // is itself the confirmation the user needs.
        if didJustInstall {
            // Fresh install just completed. Skip the panel auto-show (the Accessibility
            // prompt would be hidden by our floating-level panel anyway) and instead
            // open the Editor Integrations window so the user can install the VS Code /
            // Cursor companion extension if they want it.
            IntegrationsWindowController.shared.showWindow(nil)
        } else {
            panel?.toggle()
            viewModel?.applyInboxAwareResetIfNeeded()
            viewModel?.panelDidShow()
            viewModel?.resetSelection()
        }
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
        viewModel?.recordPanelClose()
        viewModel?.panelDidHide()
    }

    private func togglePanel() {
        panel?.toggle()
        viewModel?.exitSearch()
        if panel?.isVisible == true {
            viewModel?.applyInboxAwareResetIfNeeded()
            viewModel?.panelDidShow()
            viewModel?.resetSelection()
            // Return to list when reopening
            if navigationState.screen == .detail {
                navigationState.backToList()
            }
        } else {
            viewModel?.recordPanelClose()
            viewModel?.panelDidHide()
        }
    }

    private func handleKey(keyCode: UInt16, chars: String?, modifiers: NSEvent.ModifierFlags) {
        guard let vm = viewModel else { return }

        // Cmd+Q — quit the app. The panel intercepts all keys, so without this
        // the standard Quit shortcut would never reach NSApp. Placed before
        // every other handler so it can't be shadowed by view-state logic.
        if modifiers.contains(.command), chars == "q" {
            NSApp.terminate(nil)
            return
        }

        // Route to detail handler if in detail view
        if let detailVM = navigationState.detailViewModel, navigationState.screen == .detail {
            handleDetailKey(keyCode: keyCode, chars: chars, modifiers: modifiers, vm: detailVM)
            return
        }

        // Cmd+Up → top, Cmd+Down → bottom (works in all modes)
        if modifiers.contains(.command) {
            if keyCode == 126 { vm.moveToTop(); return }
            if keyCode == 125 { vm.moveToBottom(); return }
        }

        if vm.isSearching {
            handleSearchKey(keyCode: keyCode, chars: chars, modifiers: modifiers, vm: vm)
        } else {
            handleNormalKey(keyCode: keyCode, chars: chars, modifiers: modifiers, vm: vm)
        }
    }

    private func handleNormalKey(keyCode: UInt16, chars: String?, modifiers: NSEvent.ModifierFlags, vm: SessionListViewModel) {
        // Handle gg sequence: if g is pending and another g arrives, go to top
        if pendingG {
            pendingG = false
            if chars == "g" {
                vm.moveToTop()
                return
            }
            // Not a second g — fall through to normal handling
        }

        // Shift+Tab — move up
        if keyCode == 48 && modifiers.contains(.shift) {
            vm.moveSelectionUp()
            return
        }

        // Ctrl+key combos
        if modifiers.contains(.control), let chars {
            switch chars {
            case "d": vm.moveSelectionBy(8); return
            case "u": vm.moveSelectionBy(-8); return
            case "f": vm.moveSelectionBy(15); return
            case "b": vm.moveSelectionBy(-15); return
            default: break
            }
        }

        switch (keyCode, chars) {
        // ? — toggle help popover
        case (_, "?"):
            vm.showingHelp.toggle()
        // / to enter search
        case (_, "/"):
            if vm.pendingKillSessionId == nil && !vm.pendingMarkAllRead && vm.pendingForkSessionId == nil {
                vm.enterSearch()
            }
        // v — toggle list/tree view mode
        case (_, "v"):
            if vm.pendingKillSessionId == nil && !vm.pendingMarkAllRead && vm.pendingForkSessionId == nil {
                vm.toggleViewMode()
            }
        // r — cycle source filter: all / local only / remote only
        case (_, "r"):
            if vm.pendingKillSessionId == nil && !vm.pendingMarkAllRead && vm.pendingForkSessionId == nil {
                vm.cycleSourceFilter()
            }
        // f — request fork (Claude sessions only)
        case (_, "f"):
            if vm.pendingKillSessionId == nil && !vm.pendingMarkAllRead && vm.pendingForkSessionId == nil {
                vm.requestFork()
            }
        // G (shift+g) — go to bottom
        case (_, "G"):
            vm.moveToBottom()
        // g — start gg sequence
        case (_, "g"):
            pendingG = true
        // j, Down arrow, or Tab
        case (_, "j"), (125, _), (48, _):
            vm.moveSelectionDown()
        // k or Up arrow
        case (_, "k"), (126, _):
            vm.moveSelectionUp()
        // l or Right arrow — jump to next group (tree mode only)
        case (_, "l"), (124, _):
            if vm.isTreeMode { vm.jumpToNextGroup() }
        // h or Left arrow — jump to previous group (tree mode only)
        case (_, "h"), (123, _):
            if vm.isTreeMode { vm.jumpToPreviousGroup() }
        // Home key — go to top
        case (115, _):
            vm.moveToTop()
        // End key — go to bottom
        case (119, _):
            vm.moveToBottom()
        // U (shift+u) — mark all as read
        case (_, "U"):
            if vm.pendingKillSessionId == nil && !vm.pendingMarkAllRead && vm.pendingForkSessionId == nil {
                vm.requestMarkAllRead()
            }
        // u — mark as read (works for both local and remote rows)
        case (_, "u"):
            vm.markSelectedRowRead()
        // o — open detail view
        case (_, "o"):
            openDetailForSelected(vm: vm)
        // Enter, Return, or e
        case (36, _), (76, _), (_, "e"):
            executeSessionAction(vm: vm)
        // x — kill session process
        case (_, "x"):
            if vm.pendingKillSessionId == nil && !vm.pendingMarkAllRead && vm.pendingForkSessionId == nil {
                vm.requestKill()
            }
        // y — confirm kill, mark all read, or fork
        case (_, "y"):
            if vm.pendingKillSessionId != nil {
                vm.confirmKill()
            } else if vm.pendingMarkAllRead {
                vm.confirmMarkAllRead()
            } else if let forkId = vm.pendingForkSessionId,
                      let session = vm.sessions.first(where: { $0.id == forkId }) {
                _ = vm.confirmFork()
                SessionAction.execute(
                    target: .forkSession(session),
                    markRead: { vm.markSessionRead($0) },
                    rememberFocused: { vm.rememberFocusedSession($0) },
                    dismiss: { [weak self] in self?.dismissPanel() },
                    remoteBrowserCoordinator: remoteBrowserCoordinator
                )
            }
        // n — cancel kill, mark all read, or fork
        case (_, "n"):
            if vm.pendingKillSessionId != nil {
                vm.cancelKill()
            } else if vm.pendingMarkAllRead {
                vm.cancelMarkAllRead()
            } else if vm.pendingForkSessionId != nil {
                vm.cancelFork()
            }
        // q or Escape — cancel kill/mark all read/fork or close panel
        case (_, "q"), (53, _):
            if vm.pendingKillSessionId != nil {
                vm.cancelKill()
            } else if vm.pendingMarkAllRead {
                vm.cancelMarkAllRead()
            } else if vm.pendingForkSessionId != nil {
                vm.cancelFork()
            } else {
                dismissPanel()
            }
        default:
            break
        }
    }

    private func handleDetailKey(keyCode: UInt16, chars: String?, modifiers: NSEvent.ModifierFlags, vm: SessionDetailViewModel) {
        // Handle search mode input
        if vm.isSearching {
            handleDetailSearchKey(keyCode: keyCode, chars: chars, modifiers: modifiers, vm: vm)
            return
        }

        // Handle gg sequence
        if pendingG {
            pendingG = false
            if chars == "g" {
                vm.scrollCommand = .top
                return
            }
        }

        // Ctrl+key combos (chars from charactersIgnoringModifiers is the base letter)
        if modifiers.contains(.control), let chars {
            switch chars {
            case "d": vm.scrollCommand = .halfPageDown; return
            case "u": vm.scrollCommand = .halfPageUp; return
            case "f": vm.scrollCommand = .pageDown; return
            case "b": vm.scrollCommand = .pageUp; return
            default: break
            }
        }

        switch (keyCode, chars) {
        // q or Escape — back to list
        case (_, "q"), (53, _):
            pendingG = false
            navigationState.backToList()
        // G — jump to bottom
        case (_, "G"):
            vm.scrollCommand = .bottom
        // g — start gg sequence
        case (_, "g"):
            pendingG = true
        // j or Down arrow — line down
        case (_, "j"), (125, _):
            vm.scrollCommand = .lineDown
        // k or Up arrow — line up
        case (_, "k"), (126, _):
            vm.scrollCommand = .lineUp
        // / — enter search mode
        case (_, "/"):
            vm.enterSearch()
        // n — next search match
        case (_, "n"):
            vm.nextMatch()
        // N — previous search match
        case (_, "N"):
            vm.previousMatch()
        default:
            break
        }
    }

    private func handleDetailSearchKey(keyCode: UInt16, chars: String?, modifiers: NSEvent.ModifierFlags, vm: SessionDetailViewModel) {
        switch keyCode {
        // Escape — exit search
        case 53:
            vm.exitSearch()
        // Enter/Return — confirm search (exit typing mode but keep matches highlighted)
        case 36, 76:
            vm.isSearching = false
        // Delete/Backspace
        case 51:
            vm.deleteSearchCharacter()
        // Cmd+V — paste from clipboard
        case 9 where modifiers.contains(.command):
            if let paste = NSPasteboard.general.string(forType: .string) {
                let sanitized = paste.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "")
                vm.appendSearchCharacter(sanitized)
            }
        // Ctrl+W — delete word backward
        case 13 where modifiers.contains(.control):
            vm.deleteSearchWord()
        // Ctrl+U — clear search query
        case 32 where modifiers.contains(.control):
            vm.clearSearchQuery()
        default:
            if let chars, !chars.isEmpty, !modifiers.contains(.control), !modifiers.contains(.command) {
                vm.appendSearchCharacter(chars)
            }
        }
    }

    private func handleSearchKey(keyCode: UInt16, chars: String?, modifiers: NSEvent.ModifierFlags, vm: SessionListViewModel) {
        switch keyCode {
        // Escape — exit search
        case 53:
            vm.exitSearch()
        // Tab — toggle navigation mode
        case 48:
            if modifiers.contains(.shift) {
                vm.isNavigatingSearch = false
            } else {
                vm.isNavigatingSearch = true
            }
        // Delete/Backspace
        case 51:
            if vm.isNavigatingSearch {
                vm.isNavigatingSearch = false
            } else {
                vm.deleteSearchCharacter()
            }
        // Enter/Return — focus selected session or handle recall result
        case 36, 76:
            executeSessionAction(vm: vm)
        // Down arrow
        case 125:
            vm.moveSelectionDown()
        // Up arrow
        case 126:
            vm.moveSelectionUp()
        // Cmd+V — paste from clipboard
        case 9 where modifiers.contains(.command):
            if let paste = NSPasteboard.general.string(forType: .string) {
                if vm.isNavigatingSearch { vm.isNavigatingSearch = false }
                let sanitized = paste.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "")
                vm.appendSearchCharacter(sanitized)
            }
        // Ctrl+W — delete word backward
        case 13 where modifiers.contains(.control):
            if vm.isNavigatingSearch { vm.isNavigatingSearch = false }
            vm.deleteSearchWord()
        // Ctrl+U — clear search query
        case 32 where modifiers.contains(.control):
            if vm.isNavigatingSearch { vm.isNavigatingSearch = false }
            vm.clearSearchQuery()
        default:
            if vm.isNavigatingSearch {
                // j/k navigation while in nav mode
                if chars == "j" {
                    vm.moveSelectionDown()
                } else if chars == "k" {
                    vm.moveSelectionUp()
                } else if chars == "o" {
                    openDetailForSelected(vm: vm)
                }
            } else if let chars, !chars.isEmpty {
                vm.appendSearchCharacter(chars)
            }
        }
    }

    private func openDetailForSelected(vm: SessionListViewModel) {
        if let session = vm.selectedSession {
            pendingG = false
            vm.markSessionRead(session)
            navigationState.openDetail(for: session)
        } else if let result = vm.selectedRecallResult {
            pendingG = false
            navigationState.openDetail(for: result, session: vm.session(for: result))
        }
    }

    private func executeSessionAction(vm: SessionListViewModel) {
        let target: SessionActionTarget
        if case .remote(let remote) = vm.selectedRow {
            // Enter on a remote row opens its claude.ai URL and stamps a local
            // read receipt. Mark-read goes through `markSelectedRowRead` (not
            // the `SessionAction.execute` `markRead` closure, which is
            // local-session-typed) so the unread pill clears immediately.
            // FIXME: once `SessionAction.execute` grows a row-type-agnostic
            // mark-read closure, unify the two paths.
            vm.markSelectedRowRead()
            target = .openRemote(remote.webUrl)
        } else if let session = vm.selectedSession {
            target = session.isActive ? .activeSession(session) : .inactiveSession(session)
        } else if let result = vm.selectedRecallResult {
            target = .recallResult(result, matchedSession: vm.session(for: result))
        } else {
            return
        }

        SessionAction.execute(
            target: target,
            markRead: { vm.markSessionRead($0) },
            rememberFocused: { vm.rememberFocusedSession($0) },
            dismiss: { [weak self] in self?.dismissPanel() },
            remoteBrowserCoordinator: remoteBrowserCoordinator
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - First-launch installer

    /// Append a timestamped line to `~/Library/Logs/Seshctl/install.log`.
    /// Used for the silent-refresh path so we have an audit trail of when the
    /// hooks/symlinks were re-applied (and when they failed) without
    /// surfacing a UI dialog. Failures are intentionally silent — if we can't
    /// write the log, the rest of the launch must still proceed.
    private func appendInstallLog(_ message: String) {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Seshctl")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("install.log")
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logFile)
        }
    }

    /// Fire-and-forget background scan for stale editor-extension installs.
    /// Mirrors the silent-refresh model used for hooks: only editors that have
    /// the seshctl extension at a different version than what we ship get
    /// reinstalled. Editors that opted out (no extension installed) are left
    /// alone. All results — success and failure — go to install.log via the
    /// existing `appendInstallLog` helper.
    private func refreshEditorExtensionsInBackground() {
        let bundleURL = Bundle.main.bundleURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let installer = ExtensionInstaller(appLocator: NSWorkspaceAppLocator())
            // A missing .vsix.version sidecar makes the refresh a no-op (we
            // can't decide if anything is outdated). Surface it so botched
            // release artifacts show up in install.log instead of being
            // silently dropped.
            let sidecarMissing = (installer.bundledVersion(bundleURL: bundleURL) == nil)
            let lines = installer.refreshExistingInstalls(bundleURL: bundleURL)
            guard sidecarMissing || !lines.isEmpty else { return }
            DispatchQueue.main.async {
                if sidecarMissing {
                    self?.appendInstallLog("WARN: bundled .vsix.version sidecar missing at \(bundleURL.path)/Contents/Resources/extensions/seshctl.vsix.version — extension refresh skipped")
                }
                for line in lines {
                    self?.appendInstallLog(line)
                }
            }
        }
    }

    /// Reconcile install state against the running bundle on every launch.
    /// The pure decision lives in
    /// `FirstLaunchInstaller.reconcileInstall(...)`; this method only
    /// dispatches the side effects for each case:
    ///
    ///   - `.notRunningFromBundle` / `.noChange`: no-op, return `false`.
    ///   - `.needsFreshInstall`: show the welcome panel and (if the user
    ///     clicks Install) run the installer. Returns `true` iff the install
    ///     succeeded on this launch — callers use that to suppress the panel
    ///     auto-show so the system Accessibility prompt has the foreground.
    ///   - `.needsRefresh(reason)`: silently re-run `install(bundleURL:)` to
    ///     refresh hooks / symlinks / marker, logging both success and
    ///     failure to `~/Library/Logs/Seshctl/install.log`. Returns `false`.
    @discardableResult
    private func runFirstLaunchInstallerIfNeeded() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let decision = FirstLaunchInstaller.reconcileInstall(
            bundleURL: bundleURL, currentVersion: currentVersion
        )

        switch decision {
        case .notRunningFromBundle, .noChange:
            return false
        case .needsFreshInstall:
            return showWelcomePanelAndInstall(bundleURL: bundleURL)
        case .needsRefresh(let reason):
            do {
                _ = try FirstLaunchInstaller.install(bundleURL: bundleURL)
                appendInstallLog("silent refresh applied for bundle \(bundleURL.path) (reason: \(reason))")
            } catch {
                appendInstallLog("silent refresh failed: \(error.localizedDescription) — bundle: \(bundleURL.path)")
            }
            return false
        }
    }

    /// Present the first-launch welcome panel. Returns `true` iff the user
    /// clicked Install AND `FirstLaunchInstaller.install` succeeded. On
    /// "Quit" we terminate the app; on install failure we surface a warning
    /// alert and return `false` (the user can retry from a terminal).
    private func showWelcomePanelAndInstall(bundleURL: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Set up seshctl on this Mac?"
        alert.informativeText = """
            seshctl needs to wire itself into Claude Code and Codex. Clicking Install will:

            • Symlink ~/.local/bin/seshctl → app's bundled CLI
            • Drop ~/.local/bin/seshctl-uninstall (cleanup script)
            • Register Claude Code hooks in ~/.claude/settings.json
            • Register Codex hooks in ~/.agents/hooks.json

            After install, macOS will ask you for Accessibility permission, and (later, the first time you focus a session) Automation permission for each browser/terminal — these let seshctl raise the right window. All operations are idempotent and reversible via the 'Uninstall Seshctl…' item in seshctl's menu bar icon.
            """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Quit")

        // Ensure the alert can come to front for an .accessory-policy app.
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            do {
                _ = try FirstLaunchInstaller.install(bundleURL: bundleURL)
                return true
            } catch {
                let errorAlert = NSAlert()
                errorAlert.messageText = "seshctl install failed"
                errorAlert.informativeText = """
                    \(error.localizedDescription)

                    You can retry from a terminal with `seshctl install`.
                    """
                errorAlert.alertStyle = .warning
                errorAlert.addButton(withTitle: "Continue")
                errorAlert.runModal()
                return false
            }
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
            return false
        default:
            return false
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        // Respect the user's "Show menu bar icon" preference. Default `true`
        // when the key is unset so first-launch installs and existing users
        // (who have never written the key) see the icon.
        let prefs = UserDefaults.standard
        let shouldShow: Bool = {
            if prefs.object(forKey: AppearanceDefaults.showStatusBarIconKey) == nil {
                return AppearanceDefaults.showStatusBarIconDefault
            }
            return prefs.bool(forKey: AppearanceDefaults.showStatusBarIconKey)
        }()
        guard shouldShow else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // SF Symbol as a template image — tints to the menu bar color
        // correctly in both light and dark modes. `rectangle.stack.fill`
        // reads as a stack of sessions at menu-bar size; reasonable visual
        // shorthand for the app and on-brand with the panel's list metaphor.
        if let image = NSImage(systemSymbolName: "rectangle.stack.fill", accessibilityDescription: "Seshctl") {
            image.isTemplate = true
            item.button?.image = image
        }

        let menu = NSMenu()
        menu.delegate = self

        // 1. Show / Hide Seshctl (title updated dynamically in menuWillOpen).
        // The Cmd+Shift+S key equivalent here is purely for display — the
        // real global hotkey is registered via KeyboardShortcuts above.
        let toggle = NSMenuItem(
            title: "Show Seshctl",
            action: #selector(statusItemTogglePanel),
            keyEquivalent: "s"
        )
        toggle.keyEquivalentModifierMask = [.command, .shift]
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        // 2. Separator.
        menu.addItem(NSMenuItem.separator())

        // 3. Hide menu bar icon — flips the preference to false so this
        // status item disappears. Recovery is via the triple-dot settings
        // menu's "Show menu bar icon" toggle.
        let hideIcon = NSMenuItem(
            title: "Hide menu bar icon",
            action: #selector(statusItemHideIcon),
            keyEquivalent: ""
        )
        hideIcon.target = self
        menu.addItem(hideIcon)

        // 4. Separator.
        menu.addItem(NSMenuItem.separator())

        // 5. Uninstall Seshctl…
        let uninstall = NSMenuItem(
            title: "Uninstall Seshctl…",
            action: #selector(statusItemUninstall),
            keyEquivalent: ""
        )
        uninstall.target = self
        menu.addItem(uninstall)

        // 6. Quit Seshctl with the canonical Cmd+Q shortcut.
        let quit = NSMenuItem(
            title: "Quit Seshctl",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func statusItemTogglePanel() {
        togglePanel()
    }

    @objc private func statusItemUninstall() {
        runUninstallFlow()
    }

    @objc private func statusItemHideIcon() {
        UserDefaults.standard.set(false, forKey: AppearanceDefaults.showStatusBarIconKey)
        // The defaults observer below also reconciles, but tear down here for
        // immediate feedback in case the observer skips due to setting the
        // value while observing.
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        toggleItem = nil
    }

    // MARK: - Status item preference observer

    /// Observe `UserDefaults.didChangeNotification` so the "Show menu bar
    /// icon" toggle in SettingsPopover takes effect immediately. The
    /// notification fires for *every* defaults change (e.g. the repo accent
    /// bar toggle too), so the handler runs an idempotent reconcile.
    private func observeStatusItemPreference() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            // The queue is `.main`, so we're already on the main thread —
            // hop to the MainActor for Swift 6 concurrency checking.
            Task { @MainActor [weak self] in
                self?.reconcileStatusItemVisibility()
            }
        }
    }

    private func reconcileStatusItemVisibility() {
        let prefs = UserDefaults.standard
        let shouldShow: Bool = {
            if prefs.object(forKey: AppearanceDefaults.showStatusBarIconKey) == nil {
                return AppearanceDefaults.showStatusBarIconDefault
            }
            return prefs.bool(forKey: AppearanceDefaults.showStatusBarIconKey)
        }()
        if shouldShow && statusItem == nil {
            setupStatusItem()
        } else if !shouldShow, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            toggleItem = nil
        }
    }

    // Note: no `deinit` to remove `defaultsObserver`. AppDelegate's lifetime
    // is process-scope, and accessing the non-Sendable observer token from a
    // nonisolated deinit would require unsafe concurrency annotations under
    // Swift 6.

    /// Trigger an immediate Sparkle update check. Used by the SettingsPopover
    /// "Check for Updates…" button. The standard updater controller surfaces
    /// its own UI — either the update prompt with release notes (if a newer
    /// version is in the appcast) or its "you're up to date" sheet.
    private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    /// Shared uninstall flow used by both the status bar menu's "Uninstall
    /// Seshctl…" item and the in-app SettingsPopover's "Uninstall…" button.
    /// Presents the confirm dialog (with a session-history checkbox), calls
    /// `FirstLaunchInstaller.uninstall(...)`, surfaces success/error dialogs,
    /// and terminates the app on success.
    private func runUninstallFlow() {
        // Confirm. Terse body — the checkbox explains what the optional
        // extra deletion does, so the body stays focused on what always
        // happens.
        let confirm = NSAlert()
        confirm.messageText = "Uninstall Seshctl?"
        confirm.informativeText = """
            This removes the CLI symlinks, hook registrations, and \
            ~/.local/share/seshctl/hooks/. Seshctl.app itself is preserved — \
            drag the app to Trash to complete.
            """
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Cancel")
        let uninstallButton = confirm.addButton(withTitle: "Uninstall")
        // Cancel is the default (first button). Mark the destructive button.
        uninstallButton.hasDestructiveAction = true

        // Inline checkbox keeps the dialog single-window and native-feeling.
        let checkbox = NSButton(
            checkboxWithTitle: "Also delete session history (~/.local/share/seshctl/seshctl.db)",
            target: nil,
            action: nil
        )
        checkbox.state = .off
        confirm.accessoryView = checkbox

        // Ensure the alert can come to front for an .accessory-policy app.
        NSApp.activate(ignoringOtherApps: true)

        let response = confirm.runModal()
        guard response == .alertSecondButtonReturn else { return }

        let deleteHistory = (checkbox.state == .on)

        // Best-effort: tell each editor that has our extension to uninstall it
        // before we tear down our own install state. Failures here are logged
        // but never block the main uninstall — partial cleanup is still better
        // than no cleanup, and the user can always re-run `code --uninstall-extension`
        // by hand.
        let extensionInstaller = ExtensionInstaller(appLocator: NSWorkspaceAppLocator())
        let extensionLogs = extensionInstaller.uninstallAllEditorExtensions()
        for line in extensionLogs {
            appendInstallLog(line)
        }

        // Run the installer. On failure, surface the error and bail without
        // terminating so the user can fall back to `seshctl uninstall`.
        do {
            _ = try FirstLaunchInstaller.uninstall(deleteSessionHistory: deleteHistory)
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Uninstall failed"
            errorAlert.informativeText = """
                \(error.localizedDescription)

                You can retry from a terminal with `seshctl uninstall`.
                """
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "Continue")
            errorAlert.runModal()
            return
        }

        // Success — offer to reveal the .app in Finder, then terminate.
        // Mention TCC residue since Automation/Accessibility grants persist
        // by design and the user has to revoke them manually.
        let done = NSAlert()
        done.messageText = "Seshctl uninstalled."
        done.informativeText = """
            Drag Seshctl.app from /Applications to Trash to complete.

            macOS Automation and Accessibility grants persist by design — to \
            revoke them, open System Settings → Privacy & Security.
            """
        done.addButton(withTitle: "Show in Finder")
        done.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        let doneResponse = done.runModal()
        if doneResponse == .alertFirstButtonReturn {
            let appURL = URL(fileURLWithPath: "/Applications/Seshctl.app")
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        }
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Keep the toggle item's title in sync with the current panel state.
        // The panel hides itself on click-outside (FloatingPanel.resignKey)
        // so its visibility is the right source of truth here.
        toggleItem?.title = (panel?.isVisible == true) ? "Hide Seshctl" : "Show Seshctl"
    }
}

// MARK: - Root View

struct RootView: View {
    @ObservedObject var navigationState: NavigationState
    @ObservedObject var listViewModel: SessionListViewModel
    @ObservedObject var connectionStore: ClaudeCodeConnectionStore
    var onSessionTap: ((Session) -> Void)?
    var onOpenDetail: ((Session) -> Void)?
    var onOpenRecallDetail: ((RecallResult, Session?) -> Void)?
    /// Supplied by `AppDelegate` for the in-app SettingsPopover's Application
    /// section. Threaded through `RootView` so the AppDelegate can stay the
    /// single owner of the uninstall + terminate side effects.
    var onUninstall: (() -> Void)?
    /// Supplied by `AppDelegate` so the in-app SettingsPopover's Editor
    /// Integrations section can open the same window the post-install flow
    /// shows. Threaded through `RootView` and `SessionListView` to reach
    /// `SettingsPopover`.
    var onOpenIntegrations: (() -> Void)?
    /// Supplied by `AppDelegate` to drive Sparkle's `checkForUpdates(_:)` from
    /// the SettingsPopover's About section. Threaded through `RootView` and
    /// `SessionListView` for the same reason as `onOpenIntegrations`.
    var onCheckForUpdates: (() -> Void)?
    var onQuit: (() -> Void)?

    var body: some View {
        Group {
            switch navigationState.screen {
            case .list:
                SessionListView(
                    viewModel: listViewModel,
                    connectionStore: connectionStore,
                    onSessionTap: onSessionTap,
                    onOpenDetail: onOpenDetail,
                    onOpenRecallDetail: onOpenRecallDetail,
                    onUninstall: onUninstall,
                    onOpenIntegrations: onOpenIntegrations,
                    onCheckForUpdates: onCheckForUpdates,
                    onQuit: onQuit
                )
            case .detail:
                if let detailVM = navigationState.detailViewModel {
                    SessionDetailView(viewModel: detailVM)
                }
            }
        }
    }
}
