// A text block's inline Markdown with its image links drawn as previews in their place (Core's `Markdown.pieces`),
// and the preview itself: the image fitted to the column, opening in the browser on a tap. The Mac's twin is
// Mac/App/Shared/MarkdownImage.swift.
import SwiftUI

/// A paragraph, list item or quote: its styled text, marked for the find bar, with each image link as a `MarkdownImage`.
struct InlineMarkdown: View {
    let source: String
    /// What a find bar over it is looking for, marked where it occurs.
    @Environment(\.findHighlight) private var finding

    var body: some View {
        let pieces = Markdown.pieces(source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let spans): Text(inlineMarkdown(spans: spans).marking(finding))
                case .image(let url, let alt): MarkdownImage(url: url, alt: alt)
                }
            }
        }
    }
}

/// An image a reply links to, as wide as the column up to 480 points and at most 360 tall, rounded as a card. While it
/// loads a spinner holds its place; one that fails to load stays the link it was.
struct MarkdownImage: View {
    let url: String
    /// The link's text, read out by VoiceOver and shown if the image fails.
    let alt: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let image):
                Button { if let u = URL(string: url) { openURL(u) } } label: {
                    image.resizable().scaledToFit()
                        .frame(maxWidth: 480, maxHeight: 360, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: BriareusRadius.lg, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: BriareusRadius.lg, style: .continuous).stroke(Theme.line, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                .accessibilityHint("Opens the image")
            case .failure:
                Text(inlineMarkdown(spans: [MdSpan(flags: .link, text: alt.isEmpty ? url : alt, url: url)]))
            default:
                ProgressView().frame(height: 48)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
