import AppKit
import SeshctlCore

public struct HostAppInfo: Sendable {
    public let bundleId: String
    public let name: String
    public let icon: NSImage

    public static let unknown = HostAppInfo(
        bundleId: "",
        name: "Unknown",
        icon: NSImage(named: NSImage.applicationIconName) ?? NSImage()
    )
}

/// Resolves the host terminal app for a session, using stored DB values first,
/// falling back to PID-based lookup for live processes.
@MainActor
public final class HostAppResolver: ObservableObject {
    private var cache: [String: HostAppInfo] = [:]  // keyed by session ID
    private var claudeDesktopCache: HostAppInfo??

    public init() {}

    public func resolve(session: Session) -> HostAppInfo {
        if let cached = cache[session.id] { return cached }

        let info: HostAppInfo

        // First: use stored host app info from the database
        if let bundleId = session.hostAppBundleId, !bundleId.isEmpty {
            let icon = iconForBundleId(bundleId)
            info = HostAppInfo(
                bundleId: bundleId,
                name: session.hostAppName ?? bundleId,
                icon: icon
            )
        }
        // Second: try live PID lookup via TerminalController
        else if let pid = session.pid,
                let bundleId = TerminalController.findAppBundleId(
                    for: pid, env: TerminalController.environment
                ) {
            let icon = iconForBundleId(bundleId)
            let name = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleId
            ).first?.localizedName ?? bundleId
            info = HostAppInfo(bundleId: bundleId, name: name, icon: icon)
        } else {
            info = .unknown
        }

        cache[session.id] = info
        return info
    }

    /// The Claude desktop app, or `nil` when it isn't installed. Remote rows
    /// show its icon because Enter opens them there (see
    /// `SessionAction.openRemote`); without it they open in the browser and
    /// keep the globe. Uses the same `appBundleURL` check as that routing so
    /// the icon and the action agree. Cached for the resolver's lifetime,
    /// like per-session lookups.
    public func claudeDesktopApp(environment: SystemEnvironment = TerminalController.environment) -> HostAppInfo? {
        if let cached = claudeDesktopCache { return cached }
        let info = environment.appBundleURL(forBundleId: ClaudeDesktopApp.bundleId).map { url in
            HostAppInfo(
                bundleId: ClaudeDesktopApp.bundleId,
                name: "Claude",
                icon: NSWorkspace.shared.icon(forFile: url.path)
            )
        }
        claudeDesktopCache = .some(info)
        return info
    }

    private func iconForBundleId(_ bundleId: String) -> NSImage {
        if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: appUrl.path)
        }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }
}
