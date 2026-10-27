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
        let empty = GlobalPullsState(), all = GlobalPullsFilter(), some = GlobalPullsFilter(query: "x")
        XCTAssertNotEqual(empty.emptyTitle(.pulls, filter: all, me: "me"), empty.emptyTitle(.issues, filter: all, me: "me"))
        XCTAssertNotEqual(empty.emptyTitle(.issues, filter: all, me: "me"), empty.emptyTitle(.issues, filter: some, me: "me"))
    }

    func testIssueRefusalsFollowTheProjectPicker() {
        XCTAssertEqual(GlobalPullsFilter(repo: "O/B").issueRefusals(in: state()).map(\.project.repo), ["o/b"])
        XCTAssertTrue(GlobalPullsFilter(repo: "o/a").issueRefusals(in: state()).isEmpty)
        XCTAssertEqual(GlobalPullsFilter(query: "nothing").board(in: state(), me: nil).issueRefusals.map(\.project.repo), ["o/b"])
        XCTAssertTrue(GlobalPullsFilter(repo: "o/a").board(in: state(), me: nil).issueRefusals.isEmpty)
    }

    func testEveryProjectRefusingIssuesIsNotAnEmptyList() {
        var refused = GlobalPullsState()
        refused.replaceProjects(Project.parseList(projects)!, saved: { _ in j(#"{"pulls":[],"issuesError":"No access"}"#) })
        let plain = GlobalPullsState(), all = GlobalPullsFilter()
        XCTAssertTrue(all.issueRows(in: refused).isEmpty)
        XCTAssertNotEqual(refused.emptyTitle(.issues, filter: all, me: "me"), plain.emptyTitle(.issues, filter: all, me: "me"))
        // A refusal outside the picked project leaves that project's empty list as it is.
        XCTAssertEqual(state().emptyTitle(.issues, filter: GlobalPullsFilter(query: "zzz", repo: "o/a"), me: "me"),
                       plain.emptyTitle(.issues, filter: GlobalPullsFilter(query: "zzz"), me: "me"))
    }

    func testReviewListWithoutAnyReviewerAsksForALogin() {
        var anonymous = GlobalPullsState()
        anonymous.replaceProjects(Project.parseList(projects)!, saved: { _ in j(#"{"pulls":[]}"#) })
        let all = GlobalPullsFilter()
        let asking = anonymous.emptyTitle(.review, filter: all, me: nil)
        XCTAssertEqual(anonymous.emptyTitle(.review, filter: all, me: ""), asking)
        XCTAssertNotEqual(anonymous.emptyTitle(.review, filter: all, me: "me"), asking)
        // A project's author stands in for the login, as on its own board.
        XCTAssertNotEqual(state().emptyTitle(.review, filter: all, me: nil), asking)
    }

    func testReviewListLoginPromptFollowsTheProjectPicker() {
        var mixed = GlobalPullsState()
        mixed.replaceProjects(Project.parseList(projects)!, saved: { $0 == "o/a" ? j(#"{"pulls":[]}"#) : beta })
        let asking = GlobalPullsState().emptyTitle(.review, filter: GlobalPullsFilter(), me: nil)
        // Only Beta has an author, so Alpha alone has nobody whose review its list waits on.
        XCTAssertEqual(mixed.emptyTitle(.review, filter: GlobalPullsFilter(repo: "O/A"), me: nil), asking)
        XCTAssertNotEqual(mixed.emptyTitle(.review, filter: GlobalPullsFilter(repo: "o/b"), me: nil), asking)
        XCTAssertNotEqual(mixed.emptyTitle(.review, filter: GlobalPullsFilter(), me: nil), asking)
    }

    func testTruncatedIssuesAreNotedForThePickedProjects() {
        var cut = GlobalPullsState()
        cut.replaceProjects(Project.parseList(projects)!, saved: { $0 == "o/a" ? j(#"{"pulls":[],"issuesTruncated":true}"#) : beta })
        XCTAssertEqual(cut.issueTruncations.map(\.project.repo), ["o/a"])
        XCTAssertTrue(state().issueTruncations.isEmpty)
        XCTAssertEqual(GlobalPullsFilter(query: "nothing").board(in: cut, me: nil).issueTruncations.map(\.project.repo), ["o/a"])
        XCTAssertTrue(GlobalPullsFilter(repo: "o/b").board(in: cut, me: nil).issueTruncations.isEmpty)
        // A later full read clears the note.
        try? cut.projects[0].adopt(j(#"{"pulls":[]}"#))
        XCTAssertTrue(cut.issueTruncations.isEmpty)
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
