// Images in a reply: a block's inline text split around the links that point at an image, so each app draws a
// preview in their place instead of a link. Both apps draw the same pieces.
import Foundation

/// A piece of a text block: inline text to lay out as before, or an image to preview.
enum MdPiece: Equatable, Sendable {
    case text([MdSpan])
    /// `alt` is the link's text, empty when it only repeated the URL.
    case image(url: String, alt: String)
}

extension Markdown {
    /// The extensions a link's path ends in to count as an image when it was not written as one.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"]

    /// Whether a link opens an image: an http(s) URL, written as `![alt](url)` or whose path ends in an image extension.
    static func isImage(url: String, written image: Bool = false) -> Bool {
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
              scheme == "https" || scheme == "http", parts.host?.isEmpty == false else { return false }
        if image { return true }
        let ext = (parts.path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    /// A block's inline text with each image link taken out as an `.image` piece. A link's consecutive spans (a label
    /// with bold in it) make one image. Beside an image, the spacing and brackets that wrapped its URL and the
    /// punctuation that ended its sentence go with it, and text left with nothing else is dropped. Text without images is
    /// one piece.
    static func pieces(_ text: String?) -> [MdPiece] {
        var out: [MdPiece] = []
        var run: [MdSpan] = []
        func flushRun(beforeImage: Bool) {
            if case .image? = out.last { trim(&run, fromStart: true, while: { $0.isWhitespace || closers.contains($0) }) }
            if beforeImage { trim(&run, fromStart: false, while: { $0.isWhitespace || openers.contains($0) }) }
            if run.contains(where: { !$0.text.allSatisfy(\.isWhitespace) }) { out.append(.text(run)) }
            run = []
        }
        let spans = inline(text)
        var i = 0
        while i < spans.count {
            let span = spans[i]
            guard span.flags.contains(.link), let url = span.url, isImage(url: url, written: span.flags.contains(.image)) else {
                run.append(span); i += 1; continue
            }
            var alt = ""
            while i < spans.count, spans[i].url == url, spans[i].flags.contains(.link) { alt += spans[i].text; i += 1 }
            flushRun(beforeImage: true)
            out.append(.image(url: url, alt: alt == url ? "" : alt))
        }
        flushRun(beforeImage: false)
        return out
    }

    /// What wraps a URL on its left: the image takes them with it.
    private static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "<"]
    /// What follows a URL on its right: its closing bracket and the sentence's punctuation.
    private static let closers: Set<Character> = [")", "]", "}", "\"", "'", ">", ".", ",", ";", ":", "!", "?"]

    /// Drops characters matching `drop` from one end of the spans, across spans, removing the spans it empties.
    private static func trim(_ spans: inout [MdSpan], fromStart: Bool, while drop: (Character) -> Bool) {
        while let k = fromStart ? spans.indices.first : spans.indices.last {
            let text = spans[k].text
            let kept = fromStart ? String(text.drop(while: drop)) : String(text.reversed().drop(while: drop).reversed())
            if kept.isEmpty { spans.remove(at: k); continue }
            spans[k].text = kept
            return
        }
    }
}
