import SwiftUI

/// The line under a row while a `t` request is running or waiting for a
/// pick: "Titling…", the numbered candidates with a key hint, or a failure
/// note. Keyboard-driven: `1`–`3` pick, Esc dismisses, `t` asks again.
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
        case .ready(let titles):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 7) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 15, height: 15)
                            .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.4)))
                        Text(title)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                Text("1–\(titles.count) to use · esc keeps the current title · t for new ones")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
        case .failed:
            Text("Couldn't suggest titles · t to try again · esc to dismiss")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }
}
