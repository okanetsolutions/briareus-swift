// The board across every project's Issues and Review List tabs: repository identity, filters, refusals and whose review.
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

    func testRegularIssueFiltersAndUnassignedSelection() {
        var filter = GlobalPullsFilter()
        for (kind, value) in [(FilterKind.author, "ALICE"), (.label, "BUG"), (.assignee, BoardFilter.noAssignee)] {
            filter.issues = BoardFilter()
            filter.issues.set(kind, value)
            XCTAssertEqual(filter.issueRows(in: state()).map(\.id), ["o/a#5"])
        }
        filter.issues.set(.assignee, "BOB")
        XCTAssertEqual(filter.issueRows(in: state()).map(\.id), ["o/b#9"])
        filter.issues.set(.label, "bug")
        XCTAssertTrue(filter.issueRows(in: state()).isEmpty)
    }

    func testIssueRefusalsNameTheirProject() {
        XCTAssertEqual(state().issueRefusals.map(\.project.repo), ["o/b"])
        XCTAssertEqual(state().issueRefusals.first?.message, "Resource not accessible")
    }

    func testReviewListUsesTheSavedLoginAcrossProjects() {
        XCTAssertEqual(state().reviewRows(me: "me").map(\.id), ["o/a#2", "o/a#1"])
        var filter = GlobalPullsFilter()
        filter.pulls.set(.label, "missing")
        XCTAssertEqual(filter.reviewRows(in: state(), me: "me").map(\.id), ["o/a#2", "o/a#1"])
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

    func testEmptyTitlesDependOnTheTabAndItsOwnFilters() {
        let empty = GlobalPullsState(), all = GlobalPullsFilter()
        var some = GlobalPullsFilter()
        some.issues.set(.label, "bug")
        XCTAssertNotEqual(empty.emptyTitle(.pulls, filter: all, me: "me"), empty.emptyTitle(.issues, filter: all, me: "me"))
        XCTAssertNotEqual(empty.emptyTitle(.issues, filter: all, me: "me"), empty.emptyTitle(.issues, filter: some, me: "me"))
        XCTAssertEqual(empty.emptyTitle(.pulls, filter: all, me: "me"), empty.emptyTitle(.pulls, filter: some, me: "me"))
    }

    func testIssueRefusalsRemainVisibleUnderRegularFilters() {
        var filter = GlobalPullsFilter()
        filter.issues.set(.label, "missing")
        XCTAssertTrue(filter.issueRows(in: state()).isEmpty)
        XCTAssertEqual(filter.board(in: state(), me: nil).issueRefusals.map(\.project.repo), ["o/b"])
    }

    func testEveryProjectRefusingIssuesIsNotAnEmptyList() {
        var refused = GlobalPullsState()
        refused.replaceProjects(Project.parseList(projects)!, saved: { _ in j(#"{"pulls":[],"issuesError":"No access"}"#) })
        let plain = GlobalPullsState(), all = GlobalPullsFilter()
        XCTAssertTrue(all.issueRows(in: refused).isEmpty)
        XCTAssertNotEqual(refused.emptyTitle(.issues, filter: all, me: "me"), plain.emptyTitle(.issues, filter: all, me: "me"))

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

    func testReviewListLoginPromptUsesAnyProjectsAuthor() {
        var mixed = GlobalPullsState()
        mixed.replaceProjects(Project.parseList(projects)!, saved: { $0 == "o/a" ? j(#"{"pulls":[]}"#) : beta })
        let asking = GlobalPullsState().emptyTitle(.review, filter: GlobalPullsFilter(), me: nil)
        XCTAssertNotEqual(mixed.emptyTitle(.review, filter: GlobalPullsFilter(), me: nil), asking)
    }

    func testTruncatedIssuesRemainNotedUnderRegularFilters() {
        var cut = GlobalPullsState()
        cut.replaceProjects(Project.parseList(projects)!, saved: { $0 == "o/a" ? j(#"{"pulls":[],"issuesTruncated":true}"#) : beta })
        XCTAssertEqual(cut.issueTruncations.map(\.project.repo), ["o/a"])
        XCTAssertTrue(state().issueTruncations.isEmpty)
        var filter = GlobalPullsFilter()
        filter.issues.set(.label, "missing")
        XCTAssertEqual(filter.board(in: cut, me: nil).issueTruncations.map(\.project.repo), ["o/a"])
        // A later full read clears the note.
        try? cut.projects[0].adopt(j(#"{"pulls":[]}"#))
        XCTAssertTrue(cut.issueTruncations.isEmpty)
    }

    func testBoardRowsCountEachTabAndTheDefaultFilterGivesTotals() {
        let totals = GlobalPullsFilter().board(in: state(), me: "me")
        XCTAssertEqual(GlobalBoardTab.allCases.map { totals.count($0) }, [4, 2, 2])
        var filter = GlobalPullsFilter()
        filter.pulls.set(.reviewer, "me")
        filter.issues.set(.assignee, "bob")
        let filtered = filter.board(in: state(), me: "me")
        XCTAssertEqual(filtered.pulls.map(\.id), ["o/a#2"])
        XCTAssertEqual(filtered.issues.map(\.id), ["o/b#9"])
        XCTAssertEqual(filtered.count(.review), 2)
    }

    func testReviewTabLabelAddsTheCountOnceRead() {
        XCTAssertNotEqual(boardReviewTabLabel(count: nil), boardReviewTabLabel(count: 3))
        XCTAssertTrue(boardReviewTabLabel(count: 3).contains("3"))
    }

    func testFilterSelectionsAreIndependentSavedAndReviewStaysUnfiltered() {
        var filter = GlobalPullsFilter()
        filter[.pulls].set(.reviewer, "ME")
        filter[.pulls].hideFailingChecks = true
        filter[.issues].set(.assignee, "bob")
        XCTAssertEqual(GlobalPullsFilter(saved: filter.saved), filter)
        filter[.pulls] = BoardFilter()
        XCTAssertEqual(filter[.issues].assignee, "bob")
        filter[.review] = filter[.issues]
        XCTAssertFalse(filter[.review].isOn)
        XCTAssertTrue(filter.optionsRows(in: state(), tab: .review).isEmpty)
        XCTAssertEqual(GlobalBoardTab.pulls.filterKinds, [.author, .reviewer, .label])
        XCTAssertEqual(GlobalBoardTab.issues.filterKinds, [.author, .assignee, .label])
        XCTAssertTrue(GlobalBoardTab.review.filterKinds.isEmpty)
    }

    func testPullTogglesUseEachProjectsStackAndChecks() {
        var state = GlobalPullsState()
        state.replaceProjects(Project.parseList(projects)!, saved: { _ in j(#"""
        {"pulls":[{"number":1,"stack":{"id":1,"position":1,"total":2}},
                  {"number":2,"stack":{"id":1,"position":2,"total":2}},
                  {"number":3,"checks":"failure"}],
         "stacks":{"1":[{"number":1,"depth":1},{"number":2,"depth":2}]}}
        """#) })
        var filter = GlobalPullsFilter()
        let rows = filter.optionsRows(in: state, tab: .pulls)
        XCTAssertEqual(rows.filter { $0.stackPosition == 2 }.count, 2)
        filter.pulls.hideLaterStacked = true
        XCTAssertEqual(filter.rows(in: state).map(\.id), ["o/a#3", "o/a#1", "o/b#3", "o/b#1"])
        filter.pulls.hideFailingChecks = true
        XCTAssertEqual(filter.rows(in: state).map(\.id), ["o/a#1", "o/b#1"])
    }
}
