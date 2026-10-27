// The board across every project's Issues and Review List tabs: repository identity, search, refusals and whose review.
import XCTest
@testable import BriareusMacCore

final class BoardGlobalBoardTabsTests: XCTestCase {
    private let projects = j(#"{"projects":[{"repo":"o/a","label":"Alpha"},{"repo":"o/b","label":"Beta"}]}"#)
    private let alpha = j(#"""
    {"author":"owner","pulls":[
      {"number":1,"title":"Asks","labels":["requires-dev-review"],"assignees":["dev"],"updatedAt":"2026-10-20T00:00:00Z"},
      {"number":2,"title":"Answered","labels":["feedback-implemented"],"reviewers":[{"user":"me"}],"updatedAt":"2026-10-21T00:00:00Z"},
      {"number":3,"title":"Plain","updatedAt":"2026-10-22T00:00:00Z"}],
     "issues":[{"number":5,"title":"Crash","author":"alice","labels":["bug"],"updatedAt":"2026-10-24T00:00:00Z"},
               {"number":5,"title":"Duplicate"},{"number":0}]}
    """#)
    private let beta = j(#"""
    {"author":"me","pulls":[{"number":1,"title":"Mine","labels":["requires-dev-review"],"assignees":["me"]}],
     "issues":[{"number":9,"title":"Docs","assignees":["bob"],"updatedAt":"2026-10-25T00:00:00Z"}],
     "issuesError":"Resource not accessible"}
    """#)

    private func state() -> GlobalPullsState {
        var state = GlobalPullsState()
        state.replaceProjects(Project.parseList(projects)!, saved: { $0 == "o/a" ? alpha : beta })
        return state
    }

    func testIssuesKeepRepositoryIdentityNewestFirstAndDeduplicate() {
        let rows = state().issueRows
        XCTAssertEqual(rows.map(\.id), ["o/b#9", "o/a#5"])
        XCTAssertEqual(rows[1].project.label, "Alpha")
        XCTAssertEqual(rows[1].issue.title, "Crash")
        XCTAssertEqual(rows[1].raw, alpha["issues"][0])
    }

    func testIssueSearchAndProjectFilterMatchThePullRequestFilter() {
        for query in ["alpha", "alice", "bug", "#5", "crash"] {
            XCTAssertEqual(GlobalPullsFilter(query: query).issueRows(in: state()).map(\.id), ["o/a#5"], query)
        }
        XCTAssertEqual(GlobalPullsFilter(query: "bob").issueRows(in: state()).map(\.id), ["o/b#9"])
        XCTAssertEqual(GlobalPullsFilter(repo: "O/B").issueRows(in: state()).map(\.id), ["o/b#9"])
        XCTAssertTrue(GlobalPullsFilter(query: "crash", repo: "o/b").issueRows(in: state()).isEmpty)
    }

    func testIssueRefusalsNameTheirProject() {
        XCTAssertEqual(state().issueRefusals.map(\.project.repo), ["o/b"])
        XCTAssertEqual(state().issueRefusals.first?.message, "Resource not accessible")
    }

    func testReviewListUsesTheSavedLoginAcrossProjects() {
        XCTAssertEqual(state().reviewRows(me: "me").map(\.id), ["o/a#2", "o/a#1"])
        XCTAssertEqual(GlobalPullsFilter(repo: "o/a").reviewRows(in: state(), me: "dev").map(\.id), [])
    }

    func testReviewListFallsBackToEachProjectsAuthor() {
        // Alpha waits on its author's review of #1; Beta's author is assigned to its own pull request.
        XCTAssertEqual(state().reviewRows(me: nil).map(\.id), ["o/a#1"])
    }

    func testRenamedProjectRelabelsItsIssues() {
        var state = state()
        state.replaceProjects([Project(repo: "o/a", label: "Renamed")], saved: { _ in nil })
        XCTAssertEqual(state.issueRows.map(\.project.title), ["Renamed"])
        XCTAssertEqual(state.issueRows.map(\.id), ["o/a#5"])
    }

    func testEmptyTitlesDependOnTheTab() {
        let empty = GlobalPullsState()
        XCTAssertNotEqual(empty.emptyTitle(.pulls, filtered: false), empty.emptyTitle(.issues, filtered: false))
        XCTAssertNotEqual(empty.emptyTitle(.issues, filtered: false), empty.emptyTitle(.issues, filtered: true))
    }

    func testBoardRowsCountEachTabAndTheDefaultFilterGivesTotals() {
        let totals = GlobalPullsFilter().board(in: state(), me: "me")
        XCTAssertEqual(GlobalBoardTab.allCases.map { totals.count($0) }, [4, 2, 2])
        let filtered = GlobalPullsFilter(repo: "o/b").board(in: state(), me: "me")
        XCTAssertEqual(filtered.pulls.map(\.id), ["o/b#1"])
        XCTAssertEqual(filtered.issues.map(\.id), ["o/b#9"])
        XCTAssertEqual(filtered.count(.review), 0)
    }

    func testReviewTabLabelAddsTheCountOnceRead() {
        XCTAssertNotEqual(boardReviewTabLabel(count: nil), boardReviewTabLabel(count: 3))
        XCTAssertTrue(boardReviewTabLabel(count: 3).contains("3"))
    }
}
