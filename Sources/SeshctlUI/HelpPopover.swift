import SwiftUI

/// Content view rendered inside the help popover anchored to the question-mark
/// button in the panel header. Lists every keyboard command grouped by purpose.
///
/// Stateless — the full content is static. Presented via `.popover(isPresented:)`
/// in `SessionListView`.
public struct HelpPopover: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("Navigate") {
                row("j  ↓  tab", "next")
                row("k  ↑  ⇧tab", "previous")
                row("gg  G", "top  bottom")
                row("⌘↑  ⌘↓", "top  bottom")
                row("⌃d  ⌃u", "half page down/up")
                row("⌃f  ⌃b", "page down/up")
                row("h  l", "prev/next group (tree)")
            }

            Divider()

            section("Act") {
                row("enter  e", "focus or resume")
                row("f", "fork Claude session (then y to confirm)")
                row("o", "open detail")
                row("u  U", "mark read · mark all read")
                row("t", "regenerate title from latest messages")
                row("x", "kill process")
                row("d", "delete row (then y to confirm)")
                row("y  n", "confirm · cancel")
            }

            Divider()

            section("Search") {
                row("/", "enter search")
                row("tab  ⇧tab", "navigate · edit")
                row("⌃w  ⌃u", "delete word · clear")
                row("esc", "exit search")
            }

            Divider()

            section("View") {
                row("v", "toggle list / tree")
                row("r", "cycle source filter")
                row("c", "toggle recents (closed sessions)")
            }

            Divider()

            section("Recents") {
                row("space  x", "mark row for restore")
                row("a", "mark all · clear marks")
                row("enter", "reopen marked rows in new tabs")
                row("/", "narrow the list (every word must match)")
                row("tab", "leave typing, then mark with x / a")
            }

            Divider()

            section("Panel") {
                row("⌘⇧S", "toggle seshctl panel")
                row("⌘,", "settings")
                row("?", "this help")
                row("q  esc", "close panel")
            }
        }
        .frame(width: 360)
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                content()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func row(_ keys: String, _ description: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 110, alignment: .leading)
            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}
