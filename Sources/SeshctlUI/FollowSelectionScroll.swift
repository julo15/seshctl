import SwiftUI
import SeshctlCore

extension View {
    /// Scrolls to the selected session on appear and when `selectedIndex` changes.
    ///
    /// The row id scheme expected is `"\(session.id)-\(session.status.rawValue)"`,
    /// matching the `.id(...)` applied to each `SessionRowView` in the list and tree views.
    /// Indices outside `0..<ordered.count` are ignored — callers can attach their own
    /// `.onChange(of: selectedIndex)` afterwards to handle non-session selections
    /// (e.g. recall results in the list view).
    func followSelectionScroll(
        ordered: [Session],
        selectedIndex: Int,
        proxy: ScrollViewProxy
    ) -> some View {
        self
            .onAppear {
                if selectedIndex >= 0 && selectedIndex < ordered.count {
                    let session = ordered[selectedIndex]
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo("\(session.id)-\(session.status.rawValue)", anchor: .center)
                    }
                }
            }
            .onChange(of: selectedIndex) { newIndex in
                if newIndex >= 0 && newIndex < ordered.count {
                    let session = ordered[newIndex]
                    withAnimation(.easeOut(duration: 0.02)) {
                        proxy.scrollTo("\(session.id)-\(session.status.rawValue)", anchor: .center)
                    }
                }
            }
    }

    /// `DisplayRow` overload — same behavior, but each row's scroll target id
    /// is derived by switching on the row variant. Local rows keep the
    /// historical id shape (`"\(session.id)-\(status)"`) so rows preserve
    /// their scroll identity across status changes. Remote rows use a stable
    /// `"remote-\(id)"` id.
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
