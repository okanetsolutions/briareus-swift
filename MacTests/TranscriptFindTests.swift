// Ported from the Windows client's tests/app_find_tests.c: find searches the rendered text, ignoring case and markup,
// steps around, and keeps the current match when the transcript is read again.
import XCTest
@testable import BriareusMacCore

final class TranscriptFindTests: XCTestCase {
    private func event(_ seq: Int, _ kind: String, _ text: String) -> TranscriptBlock {
        let raw: JSON = ["seq": JSON(seq), "kind": .string(kind), "text": .string(text)]
        return .event(Event(raw)!)
    }
    private func blocks(_ list: [TranscriptBlock]) -> [(seq: Int, pieces: [String])] {
        list.map { ($0.seq, transcriptFindPieces($0, open: false)) }
    }

    func testFindSearchesTheRenderedTextAndWraps() {
        var f = TranscriptFind()
        f.search("api", in: blocks([event(1, "text", "Find **API** and `api`, then [Api](https://example.com).")]))
        XCTAssertEqual(f.matches.count, 3)
        XCTAssertEqual(f.matches[0].offset, 5); XCTAssertEqual(f.matches[1].offset, 13)
        XCTAssertEqual(f.status, "1 / 3")
        f.step(backward: true); XCTAssertEqual(f.current, 2)
        f.step(backward: false); XCTAssertEqual(f.current, 0)
        f.step(backward: false); XCTAssertEqual(f.current, 1)
        // A query can cross bold, code and link runs of one paragraph; a link's address is not searched.
        f.search("API and api", in: blocks([event(1, "text", "Find **API** and `api`, then [Api](https://example.com).")]))
        XCTAssertEqual(f.matches.count, 1)
        f.search("https://example.com", in: blocks([event(1, "text", "[Api](https://example.com)")]))
        XCTAssertEqual(f.matches.count, 0); XCTAssertEqual(f.status, "No matches")
        f.step(backward: true); XCTAssertEqual(f.current, 0)
        f.search("", in: []); XCTAssertEqual(f.status, "Find")
    }

    func testFindCountsInUTF16AndAcrossPieces() {
        var f = TranscriptFind()
        f.search("\u{E4}pfel", in: blocks([event(1, "user", "\u{1F600} \u{C4}pfel")]))
        XCTAssertEqual(f.matches.count, 1); XCTAssertEqual(f.matches[0].offset, 3)
        let reply = "User asks for TOKEN.\n\n```\nTOKEN=secret\n```\n\n| Key | Value |\n|---|---|\n| token | x |"
        f.search("token", in: blocks([event(1, "text", reply), event(2, "ask", "Which token?")]))
        XCTAssertEqual(f.matches.map(\.piece), [0, 1, 4, 1])
        XCTAssertEqual(f.matches.map(\.block), [1, 1, 1, 2])
        f.step(backward: true)
        XCTAssertEqual(f.currentInBlock, 0)
        f.step(backward: true)
        XCTAssertEqual(f.currentInBlock, 2)
    }

    func testTheCurrentMatchSurvivesARefresh() {
        var f = TranscriptFind()
        f.search("needle", in: blocks([event(1, "text", "first needle, second needle")]))
        f.step(backward: false)
        f.rebuild(blocks([event(1, "text", "first needle, second needle, third needle")]))
        XCTAssertEqual(f.matches.count, 3); XCTAssertEqual(f.current, 1)
        f.rebuild(blocks([event(1, "text", "no results remain")]))
        XCTAssertEqual(f.matches.count, 0); XCTAssertEqual(f.current, 0)
        f.rebuild(blocks([event(1, "text", "needle returns")]))
        XCTAssertEqual(f.matches.count, 1)
    }

    func testFoldedStepsAreSearchedOnlyWhileOpen() {
        let raw: JSON = ["seq": 3, "kind": "cmd", "text": "composer install"]
        let prep = TranscriptBlock.preparation([Event(raw)!])
        XCTAssertEqual(transcriptFindPieces(prep, open: false), [])
        XCTAssertEqual(transcriptFindPieces(prep, open: true), ["$ composer install"])
    }
}
