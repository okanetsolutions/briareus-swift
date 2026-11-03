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
        XCTAssertTrue(pages.canLoadMore(board: board([3, 2]), routed: true))
        XCTAssertFalse(pages.canLoadMore(board: board([3, 2], truncated: false), routed: true))
        XCTAssertFalse(pages.canLoadMore(board: board([], error: "Resource not accessible"), routed: true))
        XCTAssertFalse(pages.canLoadMore(board: .null, routed: true))
    }

    func testAServerWithoutTheRouteSaysTheListIsCutInstead() {
        let pages = IssuePages(), cut = board([3, 2])
        XCTAssertFalse(pages.canLoadMore(board: cut, routed: false))
        XCTAssertTrue(pages.cutShort(board: cut, routed: false))
        XCTAssertFalse(pages.cutShort(board: cut, routed: true))
        XCTAssertFalse(pages.cutShort(board: board([3, 2], truncated: false), routed: false))
    }

    func testPagesThatEndWithNothingNewLeaveTheListSayingItIsCut() {
        let cut = board([3, 2])
        var pages = IssuePages()
        pages.receive(page([2], next: nil), board: cut)
        XCTAssertFalse(pages.canLoadMore(board: cut, routed: true))
        XCTAssertTrue(pages.cutShort(board: cut, routed: true))
        // Pages that added issues read to the end: nothing is cut.
        var read = IssuePages()
        read.receive(page([1], next: nil), board: cut)
        XCTAssertFalse(read.cutShort(board: cut, routed: true))
    }

    func testTheNextPageReachesOnlyTheOverlapInsideTheBoardsRows() {
        var pages = IssuePages()
        pages.receive(page([7], next: 30), board: board(Array(1...20)))
        // A newer board lists more than the page said to skip.
        XCTAssertEqual(pages.query(repo: "o/r", board: board(Array(1...50)))["offset"].int, 50 - IssuePages.overlap)
        XCTAssertEqual(IssuePages().query(repo: "o/r", board: board([9, 8]))["offset"].int, 0)
    }

    func testAnIssueANewerBoardPushesPastItsEdgeStaysListed() {
        // The board lists 2...101; the first page reaches back over its last rows.
        let first = board(Array(2...101))
        var pages = IssuePages()
        XCTAssertEqual(pages.query(repo: "o/r", board: first)["offset"].int, 100 - IssuePages.overlap)
        pages.receive(page(Array(92...141), next: 140), board: first)
        // A new issue 1 pushes 101 off a fresh board, which the pages are not reset for.
        let newer = board(Array(1...100))
        let listed = pages.issues(after: rows(newer), answer: newer).map(\.summary.number)
        XCTAssertEqual(listed, Array(1...141))
        XCTAssertEqual(pages.query(repo: "o/r", board: newer)["offset"].int, 140 - IssuePages.overlap)
    }

    func testAMirrorThatStoppedShortLeavesTheListSayingItIsCut() {
        let cut = board([3, 2])
        var pages = IssuePages()
        pages.receive(IssuesPage(["issues": [["number": 1, "title": "Issue 1"]], "nextOffset": .null, "issuesTruncated": true]),
                      board: cut)
        XCTAssertFalse(pages.canLoadMore(board: cut, routed: true))
        XCTAssertTrue(pages.cutShort(board: cut, routed: true))
    }

    func testAnErrorShowsOnlyWhileLoadMoreCanReadItAgain() {
        var pages = IssuePages()
        pages.fail("offline")
        XCTAssertEqual(pages.retryError(board: board([9]), routed: true), "offline")
        XCTAssertNil(pages.retryError(board: board([9], truncated: false), routed: true))
    }

    func testFirstPageStartsAfterTheBoardThenFollowsNextOffset() {
        let b = board([9, 8, 7])
        var pages = IssuePages()
        var q = pages.query(repo: "o/r", board: b)
        XCTAssertEqual(q["repo"], "o/r")
        XCTAssertEqual(q["offset"].int, 0)
        XCTAssertEqual(q["limit"].int, IssuePages.pageSize)
        pages.receive(page([6, 5], next: 53), board: b)
        q = pages.query(repo: "o/r", board: b)
        XCTAssertEqual(q["offset"].int, 53 - IssuePages.overlap)
        XCTAssertTrue(pages.canLoadMore(board: b, routed: true))
    }

    func testKeepsEachIssueOnceAndEndsWithTheLastPage() {
        let b = board([9, 8])
        var pages = IssuePages()
        // The list moved: 8 is on the board and 6 came back on the second page.
        pages.receive(page([8, 7, 6], next: 5), board: b)
        pages.receive(page([6, 5], next: nil), board: b)
        XCTAssertEqual(pages.rows.compactMap { $0["number"].int }, [8, 7, 6, 5])
        XCTAssertEqual(pages.issues(after: rows(b), answer: b).map(\.summary.number), [9, 8, 7, 6, 5])
        XCTAssertTrue(pages.ended)
        XCTAssertFalse(pages.canLoadMore(board: b, routed: true))
    }

    func testAFailedPageIsReadAgainFromTheSameOffset() {
        let b = board([9])
        var pages = IssuePages()
        pages.receive(page([8], next: 60), board: b)
        pages.fail("offline")
        XCTAssertEqual(pages.error, "offline")
        XCTAssertTrue(pages.retries)
        XCTAssertTrue(pages.canLoadMore(board: b, routed: true))
        XCTAssertEqual(pages.query(repo: "o/r", board: b)["offset"].int, 60 - IssuePages.overlap)
        pages.reading()
        XCTAssertNil(pages.error)
        XCTAssertFalse(pages.retries)
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
        XCTAssertFalse(p.truncated)
        XCTAssertEqual(IssuesPage(j(#"{"issues":[],"nextOffset":150}"#)).nextOffset, 150)
        XCTAssertTrue(IssuesPage(j(#"{"issues":[],"nextOffset":null,"issuesTruncated":true}"#)).truncated)
    }
}
