// The Issues tab's pages past the board (Mac/Core/IssuePages.swift): when Load more is offered, where each page starts,
// and how the pages join the board's rows.
import XCTest
@testable import BriareusMacCore

final class IssuePagesTests: XCTestCase {
    private func board(_ numbers: [Int], truncated: Bool = true, error: String? = nil) -> JSON {
        ["issues": .array(numbers.map { ["number": JSON($0), "title": .string("Issue \($0)")] }),
         "issuesTruncated": JSON(truncated), "issuesError": JSON(error)]
    }
    private func page(_ numbers: [Int], next: Int?) -> IssuesPage {
        IssuesPage(["issues": .array(numbers.map { ["number": JSON($0), "title": .string("Issue \($0)")] }),
                    "nextOffset": next.map { JSON($0) } ?? .null])
    }
    private func rows(_ answer: JSON) -> [(summary: IssueSummary, raw: JSON)] {
        answer["issues"].items.compactMap { j in IssueSummary(j).map { ($0, j) } }
    }

    func testOfferedOnlyWhenTheBoardStoppedShortAndCouldReadIssues() {
        let pages = IssuePages()
        XCTAssertTrue(pages.canLoadMore(board: board([3, 2])))
        XCTAssertFalse(pages.canLoadMore(board: board([3, 2], truncated: false)))
        XCTAssertFalse(pages.canLoadMore(board: board([], error: "Resource not accessible")))
        XCTAssertFalse(pages.canLoadMore(board: .null))
    }

    func testFirstPageStartsAfterTheBoardThenFollowsNextOffset() {
        let b = board([9, 8, 7])
        var pages = IssuePages()
        var q = pages.query(repo: "o/r", board: b)
        XCTAssertEqual(q["repo"], "o/r")
        XCTAssertEqual(q["offset"].int, 3)
        XCTAssertEqual(q["limit"].int, IssuePages.pageSize)
        pages.receive(page([6, 5], next: 53), board: b)
        q = pages.query(repo: "o/r", board: b)
        XCTAssertEqual(q["offset"].int, 53)
        XCTAssertTrue(pages.canLoadMore(board: b))
    }

    func testKeepsEachIssueOnceAndEndsWithTheLastPage() {
        let b = board([9, 8])
        var pages = IssuePages()
        // The list moved: 8 is on the board and 6 came back on the second page.
        pages.receive(page([8, 7, 6], next: 5), board: b)
        pages.receive(page([6, 5], next: nil), board: b)
        XCTAssertEqual(pages.rows.compactMap { $0["number"].int }, [7, 6, 5])
        XCTAssertTrue(pages.ended)
        XCTAssertFalse(pages.canLoadMore(board: b))
    }

    func testAFailedPageIsReadAgainFromTheSameOffset() {
        let b = board([9])
        var pages = IssuePages()
        pages.receive(page([8], next: 2), board: b)
        pages.fail("offline")
        XCTAssertEqual(pages.error, "offline")
        XCTAssertTrue(pages.canLoadMore(board: b))
        XCTAssertEqual(pages.query(repo: "o/r", board: b)["offset"].int, 2)
        pages.reading()
        XCTAssertNil(pages.error)
    }

    func testListsTheBoardsIssuesThenThoseReadPastThem() {
        var pages = IssuePages()
        let b = board([9, 8])
        pages.receive(page([7, 6], next: 4), board: b)
        XCTAssertEqual(pages.issues(after: rows(b), answer: b).map(\.summary.number), [9, 8, 7, 6])
        // A newer board listing 7 itself keeps it in the board's place.
        let newer = board([7, 9, 8])
        XCTAssertEqual(pages.issues(after: rows(newer), answer: newer).map(\.summary.number), [7, 9, 8, 6])
        // A board no longer cut short lists every open issue itself.
        let whole = board([9, 8], truncated: false)
        XCTAssertEqual(pages.issues(after: rows(whole), answer: whole).map(\.summary.number), [9, 8])
    }

    func testReadsAPageAnswer() {
        let p = IssuesPage(j(#"{"repo":"o/r","issues":[{"number":4},{"number":3}],"total":120,"nextOffset":null}"#))
        XCTAssertEqual(p.issues.count, 2)
        XCTAssertNil(p.nextOffset)
        XCTAssertEqual(IssuesPage(j(#"{"issues":[],"nextOffset":150}"#)).nextOffset, 150)
    }
}
