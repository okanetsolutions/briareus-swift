// Row actions keep token and route restrictions, suggestions and run counts identical on both boards.
import XCTest
@testable import BriareusMacCore

final class BoardPullActionsTests: XCTestCase {
    private let pull = PullSummary(j(#"{"number":7,"title":"Fix login","branch":"fix/login","baseBranch":"develop","recommended":"review"}"#))!

    func testReadOnlyAndMissingRoutesDoNotOfferWrites() {
        let readOnly = BoardPullActions(pull: pull, catalog: [], canManage: false, supports: { _ in true })
        XCTAssertTrue(readOnly.errands.isEmpty)
        XCTAssertFalse(readOnly.canMerge)
        XCTAssertNil(readOnly.suggested)
        let noRoutes = BoardPullActions(pull: pull, catalog: [], canManage: true, supports: { _ in false })
        XCTAssertTrue(noRoutes.errands.isEmpty)
        XCTAssertFalse(noRoutes.canMerge)
        for missing in ["pull", "merge_pull"] {
            XCTAssertFalse(BoardPullActions(pull: pull, catalog: [], canManage: true, supports: { $0 != missing }).canMerge)
        }
    }

    func testSuggestionsAndPhoneMenuRespectAvailableRoutes() {
        let actions = BoardPullActions(pull: pull, catalog: [], canManage: true, supports: { _ in true })
        XCTAssertTrue(actions.canMerge)
        XCTAssertEqual(actions.suggested?.id, "review")
        XCTAssertTrue(actions.errands.contains { $0.id == "run" })
        XCTAssertFalse(actions.menuErrands.contains { $0.id == "run" })
        XCTAssertTrue(actions.menuErrands.contains { $0.id == "review" })
        let withoutReview = BoardPullActions(pull: pull, catalog: [], canManage: true, supports: { $0 != "review" })
        XCTAssertNil(withoutReview.suggested)
    }

    func testDraftAndMissingBranchHaveIndependentRestrictions() {
        var draft = pull
        draft.draft = true
        let draftActions = BoardPullActions(pull: draft, catalog: [], canManage: true, supports: { _ in true })
        XCTAssertFalse(draftActions.canMerge)
        XCTAssertFalse(draftActions.errands.isEmpty)
        var missingBranch = pull
        missingBranch.branch = ""
        let actions = BoardPullActions(pull: missingBranch, catalog: [], canManage: true, supports: { _ in true })
        XCTAssertTrue(actions.canMerge)
        XCTAssertTrue(actions.errands.isEmpty)
        XCTAssertNil(actions.suggested)
    }

    func testRunCountsFollowPullAssociationAndActiveState() {
        let sessions = Session.parseList(j(#"[{"id":"working","startedOnPr":7,"status":"running"},{"id":"done","startedOnPr":7,"status":"idle"},{"id":"linked","prStatus":{"number":7},"status":"preparing"},{"id":"other","startedOnPr":8,"status":"running"},{"id":"plain","status":"running"}]"#))!
        let runs = BoardPullRuns(sessions, number: 7)
        XCTAssertEqual(runs.total, 3)
        XCTAssertEqual(runs.active, 2)
        XCTAssertEqual(BoardPullRuns(sessions, number: 9).total, 0)
        XCTAssertEqual(BoardPullRuns([], number: 7).active, 0)
    }

    func testMergeConfirmationCarriesTargetAndCurrentWarnings() {
        let clear = boardPullMergeQuestion(pull)
        XCTAssertTrue(clear.contains(pull.title))
        XCTAssertTrue(clear.contains(pull.baseBranch))
        var changed = pull
        changed.mergeable = "conflicting"
        let conflicts = boardPullMergeQuestion(changed)
        XCTAssertNotEqual(conflicts, clear)
        changed.checks = "failure"
        XCTAssertNotEqual(boardPullMergeQuestion(changed), conflicts)
        changed.checks = "pending"
        let pending = boardPullMergeQuestion(changed)
        changed.checks = "expected"
        XCTAssertEqual(boardPullMergeQuestion(changed), pending)
    }
}
