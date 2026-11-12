// A pull request's review outcome as the Code reviews tab reads it (ReviewOutcomeLogic.swift): the outcome and its
// reasons, the rounds, the security pass and the approvals, and which of them an answer replaces.
import XCTest
@testable import BriareusMacCore

final class ReviewOutcomeLogicTests: XCTestCase {
    private let full = #"""
    {"reviewOutcome":{"outcome":"changes_required","stale":false,"ready":false,"enforced":true,
      "reasons":[{"code":"approved_label_ignored","effect":"note","message":"Label ignored"},
                 {"code":"fix_required","effect":"changes_required","message":"Fix the guard","findingId":4},
                 {"code":"requirement_unmet","effect":"incomplete","message":"Security pass missing"}],
      "status":{"published":false,"state":"failure"},
      "security":{"policy":"required","result":"not_run","blocking":true,"reasons":[{"code":"security_not_run","effect":"incomplete","message":"Not run"}]},
      "approvals":{"enabled":true,"result":"pending","tier":"high","required":2,"valid":1,"missing":1,"explanation":"Needs two people."}},
     "reviewRounds":{"limit":3,"used":3,"remaining":0,"limitReached":true,"continuations":1}}
    """#

    func testAnAnswerReadsEveryPart() throws {
        let o = try XCTUnwrap(ReviewOutcome(ReviewOutcome.state(j(full))))
        XCTAssertEqual(o.outcome, .changesRequired)
        XCTAssertFalse(o.stale); XCTAssertFalse(o.ready)
        XCTAssertTrue(o.enforced); XCTAssertFalse(o.published)
        XCTAssertEqual(o.reasons.map(\.code), ["approved_label_ignored", "fix_required", "requirement_unmet"])
        let security = try XCTUnwrap(o.security)
        XCTAssertEqual(security.policy, "required"); XCTAssertEqual(security.result, "not_run")
        XCTAssertTrue(security.blocking); XCTAssertTrue(security.shown); XCTAssertEqual(security.reasons.count, 1)
        let approvals = try XCTUnwrap(o.approvals)
        XCTAssertTrue(approvals.shown)
        XCTAssertEqual(approvals.required, 2); XCTAssertEqual(approvals.valid, 1); XCTAssertEqual(approvals.missing, 1)
        XCTAssertEqual(approvals.tier, "high"); XCTAssertEqual(approvals.explanation, "Needs two people.")
        let rounds = try XCTUnwrap(o.rounds)
        XCTAssertEqual(rounds.limit, 3); XCTAssertEqual(rounds.used, 3); XCTAssertTrue(rounds.limitReached)
        XCTAssertEqual(rounds.continuations, 1)
    }

    func testBlockingReasonsComeBeforeNotes() throws {
        let o = try XCTUnwrap(ReviewOutcome(ReviewOutcome.state(j(full))))
        XCTAssertEqual(o.listedReasons.map(\.code), ["fix_required", "requirement_unmet", "approved_label_ignored"])
        XCTAssertEqual(o.listedReasons.map(\.tone), [.danger, .warn, .muted])
        XCTAssertTrue(o.listedReasons[2].isNote)
    }

    func testEveryOutcomeHasItsOwnToneAndSymbol() {
        let kinds: [ReviewOutcomeKind] = [.pending, .incomplete, .changesRequired, .passed]
        XCTAssertEqual(kinds.map(\.tone), [.running, .warn, .danger, .ok])
        XCTAssertEqual(Set(kinds.map(\.symbol)).count, kinds.count)
        XCTAssertEqual(ReviewOutcomeKind(rawValue: "changes_required"), .changesRequired)
    }

    func testNoOutcomeFromAnOlderServerOrAnUnknownOne() {
        XCTAssertNil(ReviewOutcome(ReviewOutcome.state(j(#"{"codeReviews":[]}"#))))
        XCTAssertTrue(ReviewOutcome.state(j(#"{"codeReviews":[]}"#)).isNull)
        XCTAssertNil(ReviewOutcome(j(#"{"reviewOutcome":{"outcome":"bogus"}}"#)))
    }

    func testAVerdictSaveReplacesTheOutcomeAndKeepsTheRounds() throws {
        let before = ReviewOutcome.state(j(full))
        let saved = ReviewOutcome.state(j(#"{"finding":{"id":4},"reviewOutcome":{"outcome":"passed","ready":true}}"#), over: before)
        let o = try XCTUnwrap(ReviewOutcome(saved))
        XCTAssertEqual(o.outcome, .passed); XCTAssertTrue(o.ready); XCTAssertNotNil(o.readyNote)
        XCTAssertEqual(o.rounds?.used, 3)
        // A handling save answers neither: everything is kept.
        XCTAssertEqual(ReviewOutcome.state(j(#"{"review":{"id":1}}"#), over: before), before)
    }

    func testWhatIsHiddenWhenNothingIsAsked() throws {
        let o = try XCTUnwrap(ReviewOutcome(j(#"{"reviewOutcome":{"outcome":"passed","enforced":false,"stale":false,"security":{"policy":"off","result":"not_required"},"approvals":{"enabled":false,"result":"not_required"}}}"#)))
        XCTAssertEqual(o.security?.shown, false)
        XCTAssertEqual(o.approvals?.shown, false)
        XCTAssertNil(o.rounds)
        XCTAssertNil(o.statusNote); XCTAssertNil(o.staleNote); XCTAssertNil(o.readyNote)
        let stale = try XCTUnwrap(ReviewOutcome(j(#"{"reviewOutcome":{"outcome":"pending","stale":true,"enforced":true,"status":{"published":true}}}"#)))
        XCTAssertNotNil(stale.staleNote); XCTAssertNil(stale.statusNote)
    }

    func testTonesFollowTheResults() {
        func security(_ result: String) -> ReviewSecurity? { ReviewSecurity(j(#"{"policy":"advisory","result":"\#(result)"}"#)) }
        XCTAssertEqual(["passed", "failed", "incomplete", "not_run", "pending"].compactMap { security($0)?.tone }, [.ok, .danger, .warn, .warn, .running])
        XCTAssertEqual(ReviewApprovals(j(#"{"enabled":true,"result":"satisfied"}"#))?.tone, .ok)
        XCTAssertEqual(ReviewApprovals(j(#"{"enabled":true,"result":"pending"}"#))?.tone, .warn)
        XCTAssertEqual(ReviewRounds(j(#"{"used":1,"limit":3}"#))?.tone, .muted)
        XCTAssertNil(ReviewRounds(j(#"{"limit":3}"#)))
    }
}
