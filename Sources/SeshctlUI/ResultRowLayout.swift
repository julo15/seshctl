import SwiftUI
import SeshctlCore

struct ResultRowLayout<Status: View, Content: View>: View {
    @ViewBuilder var status: () -> Status
    var ageDisplay: SessionAgeDisplay
    @ViewBuilder var content: () -> Content
    var hostApp: HostAppInfo?
    /// Fallback SF Symbol name used in the host-app slot when `hostApp` is
    /// nil. Lets non-local rows (e.g., remote claude.ai sessions that have no
    /// associated macOS app) still render something recognizable in that
    /// column instead of empty space. Rendered as a secondary-colored template
    /// glyph so it reads as a placeholder, not a real app icon.
    var hostAppSystemSymbol: String? = nil
    /// Per-row accent color. When non-nil, renders a thin vertical bar just
    /// left of the main content — used for per-repo color coding so sessions
    /// from the same repo cluster visually in the flat list.
    var accentColor: Color? = nil
    var onDetail: (() -> Void)?
    /// Optional agent-kind corner badge composed over the host-app icon.
    /// When non-nil, the icon site renders a `BadgedIcon` instead of the
    /// bare `Image`, with the unified accessibility label from
    /// `iconAccessibilityLabel`. When nil, falls back to the historic
    /// bare-icon rendering — used by callers that don't carry agent
    /// identity (e.g. `RecallResultRowView`).
    var hostAppBadge: AgentBadgeSpec? = nil
    /// Unified VoiceOver label for the composite host-icon-with-badge
    /// element. Required when `hostAppBadge` is set; ignored otherwise.
    /// Build via `Session.accessibilityLabel(hostApp:agent:)`.
    var iconAccessibilityLabel: String? = nil
    /// Whether to render the timestamp at primary color. Used by callers
    /// that treat the row as unread — pulls the time forward with the rest
    /// of the unread cluster (bold sender + bold preview + accent bar).
    /// Read rows leave this `false` so the time recedes to `.secondary`.
    var isUnread: Bool = false

    var body: some View {
        // Top-aligned so the status dot, timestamp, accent bar, host icon
        // and chevron sit flush with the first line of the content cluster
        // when a row grows to multiple wrapped preview lines, instead of
        // floating to the row's vertical center.
        HStack(alignment: .top, spacing: 12) {
            // Status indicator
            Color.clear
                .frame(width: 22, height: 22)
                .overlay { status() }

            // Relative timestamp — fixed-width left column so today/yesterday/
            // older labels line up vertically across rows. Sits flush right of
            // the status dot. Typography matches the unread cluster: bold +
            // primary on unread rows, regular + secondary on read.
            Text(ageDisplay.label)
                .font(.callout)
                .fontWeight(isUnread ? .bold : .regular)
                .foregroundStyle(isUnread ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 48, alignment: .leading)

            // Per-repo accent bar slot (always 2pt wide so non-accented rows
            // line up with accented ones — when `accentColor` is nil the
            // slot renders `Color.clear`, preserving the column grid).
            // Callers gate this on `isUnread` so the bar doubles as the
            // unread marker (Gmail idiom — read rows have no bar). Stretches
            // to the HStack's vertical height so it matches the title +
            // subtitle content.
            RoundedRectangle(cornerRadius: 1)
                .fill(accentColor ?? .clear)
                .frame(width: 2)

            // Main content
            content()

            Spacer()

            // Host app icon — always takes the same slot, even for rows
            // without a host app (e.g., remote claude.ai sessions, which fall
            // through to the `hostAppSystemSymbol` placeholder). When
            // `hostAppBadge` is set, the icon is composited with an agent-kind
            // corner badge via `BadgedIcon`; otherwise renders the bare image
            // as before.
            Group {
                if let hostAppBadge {
                    let baseImage: Image? = {
                        if let hostApp {
                            return Image(nsImage: hostApp.icon)
                        } else if let hostAppSystemSymbol {
                            return Image(systemName: hostAppSystemSymbol)
                        } else {
                            return nil
                        }
                    }()
                    if let baseImage {
                        BadgedIcon(
                            base: baseImage,
                            badge: hostAppBadge,
                            accessibilityLabel: iconAccessibilityLabel ?? ""
                        )
                    } else {
                        Color.clear
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                    }
                } else {
                    Group {
                        if let hostApp {
                            Image(nsImage: hostApp.icon)
                                .resizable()
                        } else if let hostAppSystemSymbol {
                            Image(systemName: hostAppSystemSymbol)
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(.secondary)
                        } else {
                            Color.clear
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: 24, height: 24)
                }
            }

            // Detail chevron — same fixed-width slot whether or not the row
            // offers a detail action.
            Group {
                if let onDetail {
                    Button(action: onDetail) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
}
