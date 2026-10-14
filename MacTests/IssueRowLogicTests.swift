// The issue row both apps draw: its facts and their tones, an epic's progress, the epic it belongs to and what answers it.
import XCTest
@testable import BriareusMacCore

final class IssueRowLogicTests: XCTestCase {
    private func issue(_ text: String) -> IssueSummary { IssueSummary(j(text))! }

    func testPlainIssueIsUnassignedAndUnanswered() {
        let row = IssueRowContent(issue: issue(#"{"number":3,"title":"t"}"#), repo: "o/r")
        XCTAssertEqual(row.facts, [RowFact(text: "#3"), RowFact(text: "unassigned", tone: .faint)])
        XCTAssertNil(row.progress)
        XCTAssertNil(row.parentLine)
        XCTAssertFalse(row.answered)
    }

    func testFactsInOrder() {
        let i = issue(#"{"number":3,"title":"t","author":"ann","assignees":["bob"],"comments":2,"milestone":"v2","pulls":[{"number":9,"title":"p"},{"number":10,"title":"q"}]}"#)
        let row = IssueRowContent(issue: i, repo: "o/r")
        XCTAssertEqual(row.facts.count, 6)
        XCTAssertEqual(row.facts.first, RowFact(text: "#3"))
        XCTAssertTrue(row.facts[1].text.contains("@ann"))
        XCTAssertTrue(row.facts[2].text.contains("bob"))
        XCTAssertTrue(row.facts[3].text.hasPrefix("2 "))
        XCTAssertEqual(row.facts[4].text, "v2")
        XCTAssertTrue(row.facts[5].text.hasPrefix("2 "))
        XCTAssertEqual(row.facts[5].tone, .ok)
        XCTAssertTrue(row.answered)
    }

    func testParentLineIsLeftOutWhenNested() {
        let i = issue(#"{"number":3,"title":"t","parent":{"number":4,"title":"Epic"}}"#)
        XCTAssertNotNil(IssueRowContent(issue: i, repo: "o/r").parentLine)
        XCTAssertTrue(IssueRowContent(issue: i, repo: "o/r").parentLine!.contains("#4"))
        XCTAssertNil(IssueRowContent(issue: i, repo: "o/r", nested: true).parentLine)
    }

    func testEpicProgress() {
        let epic = issue(#"{"number":3,"title":"t","subIssues":{"total":4,"completed":1}}"#)
        XCTAssertEqual(IssueRowContent(issue: epic, repo: nil).progress, SubIssueProgress(done: 1, total: 4))
        XCTAssertNil(IssueRowContent(issue: issue(#"{"number":3,"title":"t","subIssues":{"total":0}}"#), repo: nil).progress)
    }

    func testProgressFractionStaysInRange() {
        XCTAssertEqual(SubIssueProgress(done: 1, total: 4).fraction, 0.25)
        XCTAssertEqual(SubIssueProgress(done: 5, total: 4).fraction, 1)
        XCTAssertEqual(SubIssueProgress(done: 0, total: 0).fraction, 0)
    }
}
