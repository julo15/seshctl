import SwiftUI

/// The line under a row while a `t` request is running or waiting for an
/// answer: "Titling…", the suggested title with a key hint, or a failure
/// note. Keyboard-driven: `y` uses it, `n` or Esc declines, `t` asks again.
struct TitleSuggestionView: View {
    let state: TitleSuggestionState

    var body: some View {
        switch state {
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Titling…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .ready(let title):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("y use · n keep current · t try again")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        case .failed:
            Text("Couldn't suggest a title · t to try again · n to dismiss")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }
}
