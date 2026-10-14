// The pull request row both apps draw: which marks it shows, in what order and tone, and who holds, wrote and reviews it.
import XCTest
@testable import BriareusMacCore

final class PullRowLogicTests: XCTestCase {
    private func pull(_ text: String) -> PullSummary { PullSummary(j(text))! }

    func testPlainPullHasNoMarksAndSaysUnassigned() {
        let row = PullRowContent(pull: pull(#"{"number":7,"title":"t"}"#), stack: nil)
        XCTAssertEqual(row.marks, [])
        XCTAssertEqual(row.who, ["unassigned"])
        XCTAssertTrue(row.unassigned)
    }

    func testMarksComeInOneOrder() {
        let p = pull(#"{"number":7,"title":"t","draft":true,"mergeable":"conflicting","checks":"failure","reviewDecision":"APPROVED"}"#)
        let stack = StackPosition(restoring: j(#"{"position":2,"total":3,"chain":[]}"#))
        let row = PullRowContent(pull: p, stack: stack, activeRuns: 2, suggested: "Fix checks")
        XCTAssertEqual(row.marks, [.running(2), .conflicts, .checks(.failed), .stack("2/3"), .review(.approved), .draft, .suggested("Fix checks")])
        XCTAssertEqual(row.marks.map(\.tone), [.running, .danger, .danger, .accent, .ok, .muted, .accent])
    }

    func testConflictLabelCountsAsConflicts() {
        let row = PullRowContent(pull: pull(#"{"number":7,"title":"t","mergeable":"mergeable","labels":[{"name":"has-conflicts"}]}"#), stack: nil)
        XCTAssertEqual(row.marks, [.conflicts])
    }

    func testChecksRollup() {
        XCTAssertEqual(ChecksState(rollup: "success"), .passed)
        XCTAssertEqual(ChecksState(rollup: "error"), .failed)
        XCTAssertEqual(ChecksState(rollup: "pending"), .pending)
        XCTAssertEqual(ChecksState(rollup: "expected").tone, .warn)
    }

    func testStackLabelIsThisPullsDepth() {
        let stack = StackPosition(restoring: j(#"{"position":1,"total":3,"chain":[{"number":7,"depth":3},{"number":5,"depth":1}]}"#))
        let row = PullRowContent(pull: pull(#"{"number":7,"title":"t"}"#), stack: stack)
        XCTAssertEqual(row.marks, [.stack("3/3")])
    }

    func testWhoNamesEachLogin() {
        let p = pull(#"{"number":7,"title":"t","author":"ann","assignees":["bob"],"reviewers":[{"user":"cy","state":"APPROVED"},{"user":""}]}"#)
        let row = PullRowContent(pull: p, stack: nil)
        XCTAssertFalse(row.unassigned)
        XCTAssertEqual(row.who.count, 3)
        XCTAssertTrue(row.who[0].contains("bob"))
        XCTAssertTrue(row.who[1].contains("@ann"))
        XCTAssertTrue(row.who[2].contains("@cy"))
    }
}
