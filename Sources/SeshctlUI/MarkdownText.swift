import AppKit
import SwiftUI
import SeshctlCore
import MarkdownUI

/// Renders a message body as either rendered markdown (when search is inactive)
/// or plain text with the existing search-match highlights (when search is
/// active — so the view-model's index-based match navigation continues to line
/// up with on-screen ranges).
struct MessageBodyText: View {
    let text: String
    var isSearchActive: Bool = false
    var query: String? = nil
    var currentMatchRange: Range<String.Index>? = nil

    var body: some View {
        if isSearchActive {
            highlightedText(text, query: query, currentMatchRange: currentMatchRange)
                .font(.system(size: 15))
        } else {
            Markdown(text)
                .markdownTheme(transcriptTheme)
                // Route link taps through NSWorkspace explicitly. SwiftUI's
                // default `openURL` action does not reliably open a browser
                // from Seshctl's non-activating `LSUIElement` panel (the app
                // is never the active app), so links rendered by MarkdownUI
                // would appear inert. Opening via NSWorkspace works regardless
                // of activation state.
                .environment(\.openURL, OpenURLAction { url in
                    NSWorkspace.shared.open(url)
                    return .handled
                })
        }
    }

    private var transcriptTheme: Theme {
        Theme.basic
            .text {
                FontFamily(.system())
                FontSize(15)
            }
            .paragraph { config in
                config.label
                    .relativeLineSpacing(.em(0.35))
                    .markdownMargin(top: 0, bottom: 18)
            }
            .listItem { config in
                config.label
                    .relativeLineSpacing(.em(0.35))
                    .markdownMargin(top: 0, bottom: 10)
            }
            .heading1 { config in
                config.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(22)
                    }
                    .relativeLineSpacing(.em(0.2))
                    .markdownMargin(top: 16, bottom: 6)
            }
            .heading2 { config in
                config.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(19)
                    }
                    .relativeLineSpacing(.em(0.2))
                    .markdownMargin(top: 14, bottom: 4)
            }
            .heading3 { config in
                config.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(17)
                    }
                    .relativeLineSpacing(.em(0.2))
                    .markdownMargin(top: 12, bottom: 4)
            }
            .heading4 { config in
                config.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(15)
                    }
                    .markdownMargin(top: 10, bottom: 2)
            }
            .code {
                FontFamily(.system(.monospaced))
                FontSize(14)
                BackgroundColor(.secondary.opacity(0.15))
            }
            .codeBlock { config in
                config.label
                    .markdownTextStyle {
                        FontFamily(.system(.monospaced))
                        FontSize(13)
                    }
                    .relativeLineSpacing(.em(0.25))
                    .padding(10)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .markdownMargin(top: 4, bottom: 12)
            }
            .blockquote { config in
                config.label
                    .relativeLineSpacing(.em(0.35))
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 3)
                    }
                    .markdownMargin(top: 4, bottom: 12)
            }
            .table { config in
                config.label
                    .markdownTableBorderStyle(.init(color: .secondary.opacity(0.3)))
                    .markdownMargin(top: 4, bottom: 12)
            }
            .tableCell { config in
                config.label
                    .relativeLineSpacing(.em(0.3))
                    .padding(6)
            }
    }
}
