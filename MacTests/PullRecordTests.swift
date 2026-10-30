// One pull request as its screen reads it: what it is before and after the `pull` answer, when merge, Update branch and
// errands are offered, what those writes send, what an edit's answer changes, and the snapshot saved to open it again.
import XCTest
@testable import BriareusMacCore

final class PullRecordTests: XCTestCase {
    private let openPull = j(#"{"state":"open","headSha":"abc","baseRef":"main","headRef":"feature","title":"T","body":"B"}"#)
    private func row(_ text: String) -> PullSummary { PullSummary(j(text))! }

    func testBoardRowStandsInUntilThePullAnswers() {
        let r = PullRecord(number: 4, pr: .null, row: row(#"{"number":4,"title":"From board","draft":true,"branch":"b","baseBranch":"main"}"#))
        XCTAssertTrue(r.isOpen)
        XCTAssertTrue(r.draft)
        XCTAssertEqual(r.title, "From board")
        XCTAssertEqual(r.head, "b")
        XCTAssertEqual(r.base, "main")
        XCTAssertFalse(PullRecord(number: 4, pr: .null, row: nil).isOpen)
    }

    func testMergeNeedsAnOpenNonDraftAtAKnownHead() {
        XCTAssertTrue(PullRecord(number: 4, pr: openPull).mergeable)
        var draft = openPull; draft["draft"] = true
        XCTAssertFalse(PullRecord(number: 4, pr: draft).mergeable)
        XCTAssertTrue(PullRecord(number: 4, pr: draft).branchUpdatable)
        var closed = openPull; closed["state"] = "closed"
        XCTAssertFalse(PullRecord(number: 4, pr: closed).branchUpdatable)
        var unread = openPull; unread["headSha"] = .null
        XCTAssertNil(PullRecord(number: 4, pr: unread).mergeArguments(repo: "o/r"))
    }

    func testBoardMergeExplainsFreshDraftClosedAndMissingCommitStates() {
        XCTAssertNil(PullRecord(number: 4, pr: openPull).mergeBlocker)
        XCTAssertEqual(PullRecord(number: 4, pr: .null).mergeBlocker, .notOpen)
        var changed = openPull
        changed["state"] = "merged"
        XCTAssertEqual(PullRecord(number: 4, pr: changed).mergeBlocker, .notOpen)
        changed = openPull
        changed["draft"] = true
        let draft = PullRecord(number: 4, pr: changed)
        XCTAssertEqual(draft.mergeBlocker, .draft)
        XCTAssertNil(draft.mergeArguments(repo: "o/r"))
        for field in ["headSha", "baseRef"] {
            changed = openPull
            changed[field] = .null
            let missingCommit = PullRecord(number: 4, pr: changed)
            XCTAssertEqual(missingCommit.mergeBlocker, .missingCommit)
            XCTAssertNil(missingCommit.mergeArguments(repo: "o/r"))
        }
    }

    func testWritesNameTheHeadAndBaseRead() {
        let r = PullRecord(number: 4, pr: openPull)
        let merge = r.mergeArguments(repo: "o/r")
        XCTAssertEqual(merge?["headSha"].string, "abc")
        XCTAssertEqual(merge?["baseRef"].string, "main")
        XCTAssertEqual(merge?["method"].string, "squash")
        XCTAssertEqual(merge?["pr"].int32, 4)
        let update = r.updateBranchArguments(repo: "o/r")
        XCTAssertEqual(update?["headSha"].string, "abc")
        XCTAssertNil(update?["method"].string)
    }

    func testErrandsLeaveOutRunAndNeedABranch() {
        let startable = BoardAction.offered(catalog: .null, pull: nil, failedChecks: 0)
        XCTAssertFalse(PullRecord(number: 4, pr: openPull).errands(startable).contains { $0.id == "run" })
        XCTAssertFalse(PullRecord(number: 4, pr: openPull).errands(startable).isEmpty)
        var noBranch = openPull; noBranch["headRef"] = .null
        XCTAssertEqual(PullRecord(number: 4, pr: noBranch).errands(startable), [])
    }

    func testMergeNotesAndHeadMoved() {
        var pr = openPull
        pr["checks"] = j(#"{"failed":2,"pending":1}"#)
        let r = PullRecord(number: 4, pr: pr)
        let files = j(#"{"pr":{"headSha":"def","mergeable":true,"mergeMethods":["merge"]}}"#)
        XCTAssertEqual(r.mergeNotes(files: files).count, 3)
        XCTAssertTrue(r.headMoved(files: files))
        XCTAssertFalse(r.headMoved(files: j(#"{"pr":{"headSha":"abc"}}"#)))
        XCTAssertFalse(r.headMoved(files: .null))
        XCTAssertEqual(PullRecord(number: 4, pr: openPull).mergeNotes(files: .null), [])
    }

    func testEditEchoChangesTheDescriptionOnlyWhenSent() {
        let answer = j(#"{"pr":{"title":"New","body":"New body"}}"#)
        XCTAssertEqual(PullRecord.editEcho(answer, sent: j(#"{"labels":["x"]}"#)).body, nil)
        let echo = PullRecord.editEcho(answer, sent: j(#"{"body":"New body"}"#))
        var r = PullRecord(number: 4, pr: openPull)
        r.apply(title: echo.title, body: echo.body)
        XCTAssertEqual(r.pr["title"].string, "New")
        XCTAssertEqual(r.pr["body"].string, "New body")
        var unread = PullRecord(number: 4, pr: .null)
        unread.apply(title: "New", body: "New body")
        XCTAssertTrue(unread.pr.isNull)
    }

    func testSnapshotRoundTrips() {
        XCTAssertNil(PullSnapshot(pr: .null, codeReviews: [], row: nil, stack: nil, body: nil, bodyAuthor: nil).json)
        let s = PullSnapshot(pr: openPull, codeReviews: j(#"[{"id":1,"status":"completed"}]"#), row: row(#"{"number":4,"title":"t"}"#), stack: nil, body: "B", bodyAuthor: "ann")
        let back = PullSnapshot(s.json)
        XCTAssertEqual(back?.pr, openPull)
        XCTAssertEqual(back?.codeReviews, j(#"[{"id":1,"status":"completed"}]"#))
        XCTAssertEqual(back?.row?.number, 4)
        XCTAssertEqual(back?.body, "B")
        XCTAssertEqual(back?.bodyAuthor, "ann")
        XCTAssertNil(PullSnapshot(nil))
    }
}
