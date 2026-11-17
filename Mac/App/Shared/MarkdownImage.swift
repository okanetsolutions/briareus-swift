// A text block's inline Markdown with its image links drawn as previews in their place (Core's `Markdown.pieces`),
// and the preview itself: the image fitted to the column, opening in the browser on a click.
import SwiftUI

/// A paragraph, list item or quote: its text as `RichText` draws it, with each image link shown as a `MarkdownImage`.
struct InlineBlock: View {
    var source: String
    var size: MarkdownSize = .body
    var color: Color = Theme.ink

    var body: some View {
        let pieces = Markdown.pieces(source)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let spans):
                    SelectableText(selectableRich(source, size: size, color: color, spans: spans))
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .image(let url, let alt):
                    MarkdownImage(url: url, alt: alt)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An image a reply links to, at most 480 by 360 points, fitted and rounded as a card. While it loads a small spinner
/// holds its place; one that fails to load stays the link it was.
struct MarkdownImage: View {
    var url: String
    /// The link's text, read out by VoiceOver and shown if the image fails.
    var alt: String

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let image):
                Button { openWebURL(url) } label: {
                    image.resizable().scaledToFit()
                        .frame(maxWidth: 480, maxHeight: 360, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: BriareusRadius.lg))
                        .overlay(RoundedRectangle(cornerRadius: BriareusRadius.lg).strokeBorder(Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(url)
                .accessibilityLabel(alt.isEmpty ? "Image" : alt)
            case .failure:
                SelectableText(selectableRich("", spans: [MdSpan(flags: .link, text: alt.isEmpty ? url : alt, url: url)]))
                    .frame(maxWidth: .infinity, alignment: .leading)
            default:
                ProgressView().controlSize(.small).frame(height: 48, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
