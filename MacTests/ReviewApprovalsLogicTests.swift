// The approvals a pull request's risk asks for as the Code reviews tab reads them (ReviewApprovalsLogic.swift): every
// approval on record, what set the tier, when Approve and Withdraw are offered, the bodies they send and what their
// answers replace of the kept outcome.
import XCTest
@testable import BriareusMacCore

final class ReviewApprovalsLogicTests: XCTestCase {
    private let requirement = #"""
    {"enabled":true,"result":"pending","headSha":"abcdef1234567890","baseRef":"main","tier":"high","required":2,"valid":1,
     "missing":1,"reviewCurrent":true,"explanation":"Needs two people.",
     "risk":{"tier":"high","reasons":[{"code":"sensitive_path","tier":"high","message":"migrations/** matched 2 files"},
                                       {"code":"size_lines","tier":"medium"}]},
     "reasons":[{"code":"security_signal","effect":"note","message":"Raised by security"},
                {"code":"approvals_missing","effect":"pending","message":"One more approval"}],
     "approvals":[
       {"id":1,"source":"briareus","by":{"userId":7,"name":"ana","githubLogin":"ana-gh"},"headSha":"abcdef1234567890",
        "at":"2026-11-12T10:00:00Z","note":"Looks right","counted":true,"reason":null},
       {"id":2,"source":"github","by":{"userId":null,"name":null,"githubLogin":"bot"},"headSha":"0000000","counted":false,
        "reason":"bot_account","message":"bot is a bot account"},
       {"id":3,"source":"briareus","by":{"userId":8,"name":"leo"},"headSha":"1111111","withdrawnAt":"2026-11-12T11:00:00Z",
        "withdrawNote":"pushed a fix","counted":false,"reason":"withdrawn"}]}
    """#

    private func approvals() throws -> ReviewApprovals { try XCTUnwrap(ReviewApprovals(j(requirement))) }

    func testTheRequirementReadsItsApprovalsAndRisk() throws {
        let a = try approvals()
        XCTAssertEqual(a.headSha, "abcdef1234567890")
        XCTAssertTrue(a.reviewCurrent)
        XCTAssertEqual(a.approvals.map(\.id), [1, 2, 3])
        XCTAssertEqual(a.riskReasons.map(\.code), ["sensitive_path", "size_lines"])
        XCTAssertEqual(a.riskReasons.map(\.tier), ["high", "medium"])
        XCTAssertEqual(a.listedReasons.map(\.code), ["approvals_missing", "security_signal"])
        let first = a.approvals[0], bot = a.approvals[1], gone = a.approvals[2]
        XCTAssertEqual(first.userId, 7); XCTAssertEqual(first.who, "ana"); XCTAssertEqual(first.note, "Looks right")
        XCTAssertNotNil(first.at); XCTAssertTrue(first.counted); XCTAssertEqual(first.tone, .ok)
        XCTAssertTrue(bot.fromGithub); XCTAssertEqual(bot.who, "@bot"); XCTAssertEqual(bot.reason, "bot_account")
        XCTAssertEqual(bot.state, "bot is a bot account"); XCTAssertEqual(bot.tone, .muted)
        XCTAssertTrue(gone.withdrawn); XCTAssertFalse(gone.counted)
        XCTAssertNotNil(gone.withdrawnAt); XCTAssertEqual(gone.withdrawNote, "pushed a fix")
        XCTAssertNil(first.withdrawnAt); XCTAssertNil(first.withdrawNote)
    }

    func testWithdrawIsOfferedOnOnesOwnApprovalsRecordedHere() throws {
        let a = try approvals()
        XCTAssertEqual(a.approvals.map { $0.canWithdraw(me: 7) }, [true, false, false])
        XCTAssertEqual(a.approvals.map { $0.canWithdraw(me: 9) }, [false, false, false])
        // Without the token's user every live approval recorded here is offered; the server refuses another person's.
        XCTAssertEqual(a.approvals.map { $0.canWithdraw(me: nil) }, [true, false, false])
    }

    func testApproveWaitsForAReviewedHeadAndOnceAPerson() throws {
        var a = try approvals()
        XCTAssertFalse(a.canApprove(me: 7), "ana's approval already counts for this head")
        XCTAssertTrue(a.canApprove(me: 8))
        XCTAssertTrue(a.canApprove(me: nil))
        a.reviewCurrent = false
        XCTAssertFalse(a.canApprove(me: 8))
        a.reviewCurrent = true; a.headSha = nil
        XCTAssertFalse(a.canApprove(me: 8))
        a.headSha = "abcdef1234567890"; a.result = "not_required"
        XCTAssertFalse(a.canApprove(me: 8))
        a.result = "satisfied"; a.enabled = false
        XCTAssertFalse(a.canApprove(me: 8))
    }

    func testTheBodiesNameTheHeadAndKeepANoteOnlyWhenGiven() throws {
        let approve = ReviewApprovalWrite.approveArguments(repo: "o/r", number: 9, headSha: "abc", note: "  ")
        XCTAssertEqual(approve, ["repo": "o/r", "pr": 9, "headSha": "abc"])
        XCTAssertEqual(ReviewApprovalWrite.approveArguments(repo: "o/r", number: 9, headSha: "abc", note: " ok \n")["note"], "ok")
        let approval = try approvals().approvals[0]
        let withdraw = ReviewApprovalWrite.withdrawArguments(repo: "o/r", number: 9, approval: approval, note: "pushed a fix")
        XCTAssertEqual(withdraw, ["repo": "o/r", "pr": 9, "approvalId": 1, "note": "pushed a fix"])
    }

    func testAnApprovalAnswerReplacesTheOutcomeAndKeepsTheRounds() throws {
        let kept = ReviewOutcome.state(j(#"""
        {"reviewOutcome":{"outcome":"passed","approvals":{"enabled":true,"result":"pending","required":1,"valid":0,"missing":1}},
         "reviewRounds":{"limit":3,"used":1}}
        """#))
        let answered = ReviewOutcome.state(j(#"""
        {"approval":{"id":5},"reviewOutcome":{"outcome":"passed","ready":true,
          "approvals":{"enabled":true,"result":"satisfied","required":1,"valid":1,"missing":0}}}
        """#), from: .approval, over: kept)
        let o = try XCTUnwrap(ReviewOutcome(answered))
        XCTAssertTrue(o.ready)
        XCTAssertEqual(o.approvals?.result, "satisfied")
        XCTAssertEqual(o.rounds?.used, 1)
        // An answer carrying the requirement alone puts it in the kept outcome.
        let alone = ReviewOutcome.state(j(#"{"approvals":{"enabled":true,"result":"satisfied","required":1,"valid":1,"missing":0}}"#),
                                        from: .approval, over: kept)
        let o2 = try XCTUnwrap(ReviewOutcome(alone))
        XCTAssertEqual(o2.outcome, .passed)
        XCTAssertEqual(o2.approvals?.valid, 1)
        XCTAssertEqual(o2.rounds?.limit, 3)
        // An answer with neither changes nothing.
        XCTAssertEqual(ReviewOutcome.state(j(#"{"approval":{"id":5}}"#), from: .approval, over: kept), kept)
    }

    func testEachWriteNamesWhatItsAnswerReplaces() {
        XCTAssertEqual(ReviewOutcome.source(after: "approve_pull"), .approval)
        XCTAssertEqual(ReviewOutcome.source(after: "withdraw_pull_approval"), .approval)
        XCTAssertEqual(ReviewOutcome.source(after: "update_code_review_finding"), .verdict)
        XCTAssertEqual(ReviewOutcome.source(after: "update_code_review"), .other)
    }

    func testApprovalsOnRecordStayShownWhenTheTierAsksForNone() throws {
        let lowered = try XCTUnwrap(ReviewApprovals(j(#"""
        {"enabled":true,"result":"not_required","tier":"low","required":0,"valid":0,"missing":0,
         "approvals":[{"id":1,"source":"briareus","by":{"userId":7},"headSha":"abc","counted":false,"reason":"head_moved"}]}
        """#)))
        XCTAssertTrue(lowered.shown)
        XCTAssertEqual(lowered.tone, .muted)
        XCTAssertFalse(lowered.canApprove(me: 8))
        // Nothing asked and nothing on record: hidden, as before.
        let none = try XCTUnwrap(ReviewApprovals(j(#"{"enabled":true,"result":"not_required","tier":"low","required":0,"approvals":[]}"#)))
        XCTAssertFalse(none.shown)
        // Without a policy the server lists approvals as not counting; still hidden.
        let off = try XCTUnwrap(ReviewApprovals(j(#"""
        {"enabled":false,"result":"not_required","approvals":[{"id":1,"source":"briareus","by":{},"headSha":"abc","counted":false,"reason":"policy_off"}]}
        """#)))
        XCTAssertFalse(off.shown)
    }
}
