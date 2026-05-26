import SwiftUI
import SeshctlCore

extension View {
    /// Scrolls to the selected row on appear and when `selectedIndex` changes.
    /// Each row's scroll-target id is derived by `rowViewIdentity(for:)`, which
    /// returns the bare `session.id` for local rows and `"remote-<id>"` for
    /// remote rows. Identity stays stable across status changes so SwiftUI can
    /// animate row reorders (see `rowViewIdentity` for the rationale).
    func followSelectionScroll(
        ordered: [DisplayRow],
        selectedIndex: Int,
        proxy: ScrollViewProxy
    ) -> some View {
        self
            .onAppear {
                if selectedIndex >= 0 && selectedIndex < ordered.count {
                    let id = rowViewIdentity(for: ordered[selectedIndex])
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onChange(of: selectedIndex) { newIndex in
                if newIndex >= 0 && newIndex < ordered.count {
                    let id = rowViewIdentity(for: ordered[newIndex])
                    withAnimation(.easeOut(duration: 0.02)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
    }
}

/// Stable scroll-target id for a `DisplayRow`. Identity stays constant across
/// status changes so SwiftUI can animate row reorders (status often flips on
/// the same refresh tick that bumps `updatedAt` and re-sorts the row, so any
/// status-dependent id would tear the view down right when it should move).
func rowViewIdentity(for row: DisplayRow) -> String {
    switch row {
    case .local(let session):
        return session.id
    case .remote(let remote):
        return "remote-\(remote.id)"
    }
}
