// Images in a reply's text: which links preview as images and how a block's text splits around them.
import XCTest
@testable import BriareusMacCore

final class MarkdownImagesTests: XCTestCase {
    /// Pieces written out as text or <img url|alt>, so a split reads as one expectation.
    private func pieces(_ text: String) -> [String] {
        Markdown.pieces(text).map {
            switch $0 {
            case .text(let spans): return spans.map(\.text).joined()
            case .image(let url, let alt): return "<img \(url)|\(alt)>"
            }
        }
    }

    func testImageSyntaxIsMarkedOnItsSpans() {
        let spans = Markdown.inline("![a **b**](https://x.example/d) [l](https://x.example/d)")
        XCTAssertEqual(spans.map { $0.flags.contains(.image) }, [true, true, false, false])
    }

    func testWhichLinksAreImages() {
        XCTAssertTrue(Markdown.isImage(url: "https://x.example/a/shot.PNG"))
        XCTAssertTrue(Markdown.isImage(url: "https://x.example/a.jpeg?size=2#top"))
        XCTAssertFalse(Markdown.isImage(url: "https://x.example/page"))
        XCTAssertFalse(Markdown.isImage(url: "https://x.example/page?f=a.png"))
        XCTAssertTrue(Markdown.isImage(url: "https://github.com/user-attachments/assets/1234", written: true))
        XCTAssertFalse(Markdown.isImage(url: "file:///tmp/a.png"))
        XCTAssertFalse(Markdown.isImage(url: "u.png", written: true))
    }

    func testABareImageURLBecomesAnImage() {
        XCTAssertEqual(pieces("Here: https://x.example/s.png"), ["Here:", "<img https://x.example/s.png|>"])
    }

    func testImageSyntaxKeepsItsAltText() {
        XCTAssertEqual(pieces("![a **diagram**](https://x.example/d)"), ["<img https://x.example/d|a diagram>"])
    }

    func testTextAroundImagesStaysAndBlankTextBetweenIsDropped() {
        XCTAssertEqual(pieces("Before\nhttps://x.example/1.gif\nhttps://x.example/2.gif\nafter"),
                       ["Before", "<img https://x.example/1.gif|>", "<img https://x.example/2.gif|>", "after"])
    }

    func testTextWithoutImagesIsOnePieceWithItsSpans() {
        let text = "see [docs](https://x.example/page) and **this**"
        XCTAssertEqual(Markdown.pieces(text), [.text(Markdown.inline(text))])
        XCTAssertEqual(Markdown.pieces(""), [])
    }

    func testPunctuationAroundAnImageGoesWithIt() {
        XCTAssertEqual(pieces("See https://x.example/a.png."), ["See", "<img https://x.example/a.png|>"])
        XCTAssertEqual(pieces("A shot (https://x.example/a.png), then more."),
                       ["A shot", "<img https://x.example/a.png|>", "then more."])
        XCTAssertEqual(pieces("<https://x.example/a.png>!"), ["<img https://x.example/a.png|>"])
    }

    func testHTMLImageTagsAreImages() {
        XCTAssertEqual(pieces(#"<img width="300" alt="Login screen" src="https://x.example/assets/1"> after"#),
                       ["<img https://x.example/assets/1|Login screen>", "after"])
        XCTAssertEqual(pieces("<IMG src='https://x.example/a.png'/>"), ["<img https://x.example/a.png|>"])
        XCTAssertEqual(pieces("<img src=https://x.example/a.png>"), ["<img https://x.example/a.png|>"])
        let tag = Markdown.inline(#"<img src="https://x.example/a.png">"#)
        XCTAssertEqual(tag.map(\.flags), [[.link, .image]])
    }

    func testOtherTagsAndRelativeImagesStayText() {
        XCTAssertEqual(pieces(#"<img src="docs/a.png"> and <imgx src="https://x.example/page">"#).count, 1)
        XCTAssertEqual(Markdown.plain(#"`<img src="https://x.example/a.png">`"#), #"<img src="https://x.example/a.png">"#)
    }
}
