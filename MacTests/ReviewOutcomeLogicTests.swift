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
        let saved = ReviewOutcome.state(j(#"{"finding":{"id":4},"reviewOutcome":{"outcome":"passed","ready":true}}"#), from: .verdict, over: before)
        let o = try XCTUnwrap(ReviewOutcome(saved))
        XCTAssertEqual(o.outcome, .passed); XCTAssertTrue(o.ready); XCTAssertNotNil(o.readyNote)
        XCTAssertEqual(o.rounds?.used, 3)
        // A handling save answers neither: everything is kept.
        XCTAssertEqual(ReviewOutcome.state(j(#"{"review":{"id":1}}"#), from: .other, over: before), before)
        // A verdict save the server could not compute an outcome for leaves none standing, and keeps the rounds.
        let uncomputed = ReviewOutcome.state(j(#"{"finding":{"id":4}}"#), from: .verdict, over: before)
        XCTAssertNil(ReviewOutcome(uncomputed)); XCTAssertEqual(uncomputed["reviewRounds"], before["reviewRounds"])
        // A read replaces both: what it lacks is gone.
        let reread = ReviewOutcome.state(j(#"{"reviewOutcome":{"outcome":"pending"}}"#), from: .read, over: before)
        XCTAssertNil(ReviewOutcome(reread)?.rounds)
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

    func testTheLinesTellApartWhatTheyRead() {
        // A required pass reads apart from an advisory one with the same result, and a blocking one counts as required.
        let required = ReviewSecurity(j(#"{"policy":"required","result":"failed"}"#))!.line
        XCTAssertNotEqual(required, ReviewSecurity(j(#"{"policy":"advisory","result":"failed"}"#))!.line)
        XCTAssertEqual(ReviewSecurity(j(#"{"policy":"advisory","result":"failed","blocking":true}"#))!.line, required)
        // Rounds with a limit, without one, and with rounds granted past it each read differently.
        let lines = [#"{"used":2,"limit":3}"#, #"{"used":2,"limit":0}"#, #"{"used":2,"limit":3,"continuations":1}"#]
            .compactMap { ReviewRounds(j($0))?.line }
        XCTAssertEqual(Set(lines).count, 3)
        // The approvals line names the tier only when there is one.
        let tiered = ReviewApprovals(j(#"{"enabled":true,"result":"pending","required":2,"valid":1,"tier":"high"}"#))!.line
        let untiered = ReviewApprovals(j(#"{"enabled":true,"result":"pending","required":2,"valid":1}"#))!.line
        XCTAssertTrue(tiered.contains("high")); XCTAssertFalse(untiered.contains("high"))
    }

    func testAReasonWithoutEffectOrMessageIsANoteThatStillSaysSomething() {
        let reasons = ReviewReason.list(j(#"[{"code":"label_check_failed"},{"effect":"pending"},{"code":"head_moved","effect":"pending","message":"Moved"}]"#))
        XCTAssertEqual(reasons.map(\.code), ["label_check_failed", "head_moved"])
        XCTAssertTrue(reasons[0].isNote); XCTAssertFalse(reasons[0].message.isEmpty)
        XCTAssertEqual(reasons[1].message, "Moved"); XCTAssertNotEqual(reasons[0].id, reasons[1].id)
    }

    func testTheNotesFollowTheRoundsAndTheStatusWrite() throws {
        func outcome(_ o: String, rounds: String = "null") throws -> ReviewOutcome {
            try XCTUnwrap(ReviewOutcome(j(#"{"reviewOutcome":\#(o),"reviewRounds":\#(rounds)}"#)))
        }
        // A stale outcome past the round limit says something else than one whose next review can still run.
        let open = try outcome(#"{"outcome":"pending","stale":true}"#, rounds: #"{"used":1,"limit":3}"#)
        let spent = try outcome(#"{"outcome":"incomplete","stale":true}"#, rounds: #"{"used":3,"limit":3,"limitReached":true}"#)
        XCTAssertNotNil(open.staleNote); XCTAssertNotNil(spent.staleNote); XCTAssertNotEqual(open.staleNote, spent.staleNote)
        // An unpublished status: not yet, retried after a refusal, or refused for good, each with GitHub's reason.
        let notYet = try outcome(#"{"outcome":"passed","enforced":true,"status":{"published":false}}"#)
        let retried = try outcome(#"{"outcome":"passed","enforced":true,"status":{"published":false,"error":"Resource not accessible","retryAt":"2026-11-12T15:00:00Z"}}"#)
        let refused = try outcome(#"{"outcome":"passed","enforced":true,"status":{"published":false,"error":"Resource not accessible","retryAt":null}}"#)
        XCTAssertNil(notYet.statusError); XCTAssertTrue(retried.statusRetried); XCTAssertFalse(refused.statusRetried)
        let notes = [notYet, retried, refused].compactMap(\.statusNote)
        XCTAssertEqual(Set(notes).count, 3)
        XCTAssertTrue(retried.statusNote?.contains("Resource not accessible") ?? false)
    }

    func testASecurityPassReadsItsPolicyAndReasons() throws {
        let off = try XCTUnwrap(ReviewSecurity(j(#"{"policy":"off","result":"failed"}"#)))
        let advisory = try XCTUnwrap(ReviewSecurity(j(#"{"policy":"advisory","result":"failed","reasons":[{"code":"n","effect":"note","message":"N"},{"code":"f","effect":"failed","message":"F"}]}"#)))
        XCTAssertNotEqual(off.line, advisory.line)
        XCTAssertEqual(advisory.listedReasons.map(\.code), ["f", "n"])
        XCTAssertEqual(advisory.listedReasons.first?.tone, .danger)
    }
}
