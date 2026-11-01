// A pull request's code reviews (Mac/Core/CodeReviewLogic.swift): what `GET /pulls/{number}/code-reviews` answers, read
// into reviews and findings, with their verdicts, places, counts and the findings a pull request still carries; marking a
// review handled, overruling a finding's verdict, and folding either answer back into the list.
import XCTest
@testable import BriareusMacCore

final class CodeReviewLogicTests: XCTestCase {
    private func finding(_ text: String) -> CodeReviewFinding? { CodeReviewFinding(j(text)) }
    private func review(_ text: String) -> CodeReview? { CodeReview(j(text)) }

    // MARK: - Findings

    func testAFindingReadsEveryField() {
        let f = finding(#"""
        {"id":7,"severity":"high","type":"security","shouldFix":"fix","verification":"confirmed","title":"SQL injection",
         "body":"The query is built by hand.","filePath":"app/Db.php","startLine":12,"endLine":18,"comments":"Reproduced locally.",
         "createdAt":"2026-10-01T00:00:00Z"}
        """#)!
        XCTAssertEqual(f.id, 7)
        XCTAssertEqual(f.severity, "high")
        XCTAssertEqual(f.type, "security")
        XCTAssertEqual(f.verdict, .fix)
        XCTAssertEqual(f.verification, .confirmed)
        XCTAssertEqual(f.title, "SQL injection")
        XCTAssertEqual(f.body, "The query is built by hand.")
        XCTAssertEqual(f.filePath, "app/Db.php")
        XCTAssertEqual(f.startLine, 12); XCTAssertEqual(f.endLine, 18)
        XCTAssertEqual(f.comments, "Reproduced locally.")
    }

    func testAFindingDefaultsWhatTheServerLeftOutAndNeedsAnID() {
        let f = finding(#"{"id":1,"severity":"","type":"","shouldFix":null,"verification":null,"title":"","body":"","filePath":"","comments":""}"#)!
        XCTAssertEqual(f.severity, "medium")
        XCTAssertNil(f.type); XCTAssertNil(f.verdict); XCTAssertNil(f.verification)
        XCTAssertFalse(f.title.isEmpty)
        XCTAssertNil(f.body); XCTAssertNil(f.filePath); XCTAssertNil(f.comments)
        XCTAssertNil(f.startLine); XCTAssertNil(f.endLine)
        XCTAssertNil(f.location)
        // Spellings the server does not use are no verdict.
        let odd = finding(#"{"id":2,"shouldFix":"dismissed","verification":"maybe","startLine":"4"}"#)!
        XCTAssertNil(odd.verdict); XCTAssertNil(odd.verification); XCTAssertNil(odd.startLine)
        XCTAssertNil(finding(#"{"title":"no id"}"#))
        XCTAssertNil(finding(#"{"id":"7","title":"string id"}"#))
        XCTAssertNil(CodeReviewFinding(.null))
        XCTAssertEqual(finding(#"{"id":3.9}"#)?.id, 3)
    }

    func testVerdictAndVerificationMapTheServersSpellings() {
        XCTAssertEqual(CodeReviewVerdict.allCases.map(\.rawValue), ["fix", "optional", "dismiss"])
        XCTAssertEqual(CodeReviewVerdict.fix.tone, .danger)
        XCTAssertEqual(CodeReviewVerdict.optional.tone, .warn)
        XCTAssertEqual(CodeReviewVerdict.dismiss.tone, .muted)
        XCTAssertEqual(Set(CodeReviewVerdict.allCases.map(\.title)).count, 3)
        XCTAssertEqual(CodeReviewVerification(rawValue: "confirmed")?.tone, .ok)
        XCTAssertEqual(CodeReviewVerification(rawValue: "plausible")?.tone, .warn)
        XCTAssertNotEqual(CodeReviewVerification.confirmed.title, CodeReviewVerification.plausible.title)
    }

    func testSeverityLabelsAndTones() {
        let cases: [(String, String, RowTone)] = [("critical", "CRIT", .danger), ("high", "HIGH", .danger), ("medium", "MED", .warn),
                                                  ("low", "LOW", .muted), ("blocker", "MED", .warn)]
        for (severity, label, tone) in cases {
            let f = finding(#"{"id":1,"severity":"\#(severity)"}"#)!
            XCTAssertEqual(f.severityLabel, label, severity)
            XCTAssertEqual(f.severityTone, tone, severity)
        }
    }

    func testLocationNamesTheFileAndItsLines() {
        let cases: [(String, String?)] = [
            (#"{"id":1,"filePath":"src/a.swift","startLine":12,"endLine":18}"#, "src/a.swift:12-18"),
            (#"{"id":1,"filePath":"src/a.swift","startLine":12,"endLine":12}"#, "src/a.swift:12"),
            (#"{"id":1,"filePath":"src/a.swift","startLine":12,"endLine":3}"#, "src/a.swift:12"),
            (#"{"id":1,"filePath":"src/a.swift","startLine":12}"#, "src/a.swift:12"),
            (#"{"id":1,"filePath":"src/a.swift","startLine":0,"endLine":4}"#, "src/a.swift"),
            (#"{"id":1,"filePath":"src/a.swift","endLine":4}"#, "src/a.swift"),
            (#"{"id":1,"filePath":"src/a.swift"}"#, "src/a.swift"),
            (#"{"id":1,"startLine":12,"endLine":18}"#, nil),
        ]
        for (text, location) in cases { XCTAssertEqual(finding(text)?.location, location, text) }
    }

    // MARK: - Reviews

    private let answer = #"""
    {"codeReviews":[
      {"id":12,"sessionId":"s-12","projectId":3,"repo":"o/r","prNumber":42,"branch":"feat/x","headSha":"abcdef1234567","userId":1,
       "providerId":2,"provider":"codex","model":"gpt-5","effort":"high","inputTokens":1500,"outputTokens":500,"costUsd":0.42,
       "costEstimated":true,"unpricedTurns":2,"status":"completed","summary":"Two findings.","completedAt":"2026-10-02T10:00:00.250Z",
       "createdAt":"2026-10-02T09:00:00Z","updatedAt":"2026-10-02T10:00:00Z",
       "findings":[{"id":1,"severity":"high","title":"A","shouldFix":"fix"},{"title":"no id"},{"id":2,"severity":"low","title":"B","shouldFix":"dismiss"}]},
      {"id":11,"status":"failed","provider":"claude","findings":[]},
      {"status":"completed"},
      {"id":10,"status":"weird"}]}
    """#

    func testParseKeepsValidReviewsNewestFirst() {
        let reviews = CodeReview.parse(j(answer))
        XCTAssertEqual(reviews.map(\.id), [12, 11, 10])
        let r = reviews[0]
        XCTAssertEqual(r.sessionID, "s-12")
        XCTAssertEqual(r.repo, "o/r"); XCTAssertEqual(r.prNumber, 42); XCTAssertEqual(r.branch, "feat/x")
        XCTAssertEqual(r.headSha, "abcdef1234567")
        XCTAssertEqual(r.provider, "codex"); XCTAssertEqual(r.model, "gpt-5"); XCTAssertEqual(r.effort, "high")
        XCTAssertEqual(r.inputTokens, 1500); XCTAssertEqual(r.outputTokens, 500)
        XCTAssertEqual(r.costUsd, 0.42); XCTAssertTrue(r.costEstimated); XCTAssertEqual(r.unpricedTurns, 2)
        XCTAssertEqual(r.status, .completed)
        XCTAssertEqual(r.summary, "Two findings.")
        XCTAssertEqual(r.createdAt, Date(timeIntervalSince1970: 1_790_931_600))
        XCTAssertEqual(r.completedAt?.timeIntervalSince1970 ?? 0, 1_790_935_200.25, accuracy: 0.001)
        // A finding without an id is left out.
        XCTAssertEqual(r.findings.map(\.id), [1, 2])
        XCTAssertEqual(CodeReview.parse(.null), [])
        XCTAssertEqual(CodeReview.parse(j(#"{"codeReviews":{}}"#)), [])
    }

    func testAReviewDefaultsWhatTheServerLeftOut() {
        let r = review(#"{"id":5}"#)!
        XCTAssertNil(r.sessionID); XCTAssertEqual(r.repo, ""); XCTAssertNil(r.prNumber); XCTAssertEqual(r.branch, "")
        XCTAssertNil(r.headSha); XCTAssertEqual(r.provider, ""); XCTAssertNil(r.model); XCTAssertNil(r.effort)
        XCTAssertNil(r.inputTokens); XCTAssertNil(r.outputTokens); XCTAssertNil(r.costUsd)
        XCTAssertFalse(r.costEstimated); XCTAssertEqual(r.unpricedTurns, 0)
        XCTAssertEqual(r.status, .running)
        XCTAssertNil(r.summary); XCTAssertNil(r.createdAt); XCTAssertNil(r.completedAt)
        XCTAssertEqual(r.findings, [])
        // A cost flag that is not exactly true is not an estimate; a date that is not ISO-8601 is none.
        let odd = review(#"{"id":5,"costEstimated":1,"createdAt":"yesterday","sessionId":"","summary":""}"#)!
        XCTAssertFalse(odd.costEstimated); XCTAssertNil(odd.createdAt); XCTAssertNil(odd.sessionID); XCTAssertNil(odd.summary)
        XCTAssertNil(review(#"{"status":"completed"}"#))
    }

    func testStatusMapsEveryRunState() {
        let cases: [(String, CodeReviewStatus, RowTone)] = [("running", .running, .running), ("completed", .completed, .ok),
                                                            ("failed", .failed, .danger), ("weird", .running, .running)]
        for (status, expected, tone) in cases {
            let r = review(#"{"id":1,"status":"\#(status)"}"#)!
            XCTAssertEqual(r.status, expected, status)
            XCTAssertEqual(r.status.tone, tone, status)
        }
        XCTAssertEqual(Set([CodeReviewStatus.running, .completed, .failed].map(\.title)).count, 3)
    }

    func testMetaJoinsWhatItRanOnAndWhatItCost() {
        let r = CodeReview.parse(j(answer))[0]
        XCTAssertEqual(r.meta, "codex \u{00B7} gpt-5 \u{00B7} high \u{00B7} abcdef1 \u{00B7} 2.0k tok \u{00B7} ~$0.42")
        // Only what is known; a priced run is not marked as an estimate.
        XCTAssertEqual(review(#"{"id":1,"provider":"claude","costUsd":1.5}"#)!.meta, "claude \u{00B7} $1.50")
        XCTAssertEqual(review(#"{"id":1,"outputTokens":800}"#)!.meta, "800 tok")
        XCTAssertEqual(review(#"{"id":1,"headSha":"abc"}"#)!.meta, "abc")
        XCTAssertEqual(review(#"{"id":1}"#)!.meta, "")
    }

    // MARK: - Counts

    func testCountsSplitFindingsByVerdict() {
        let r = review(#"""
        {"id":1,"findings":[{"id":1,"shouldFix":"fix"},{"id":2,"shouldFix":"fix"},{"id":3,"shouldFix":"optional"},
                            {"id":4,"shouldFix":"dismiss"},{"id":5},{"id":6,"shouldFix":null}]}
        """#)!
        let c = r.counts
        XCTAssertEqual(c.fix, 2); XCTAssertEqual(c.optional, 1); XCTAssertEqual(c.dismissed, 1); XCTAssertEqual(c.pending, 2)
        XCTAssertEqual(c.total, 6)
        XCTAssertEqual(c, CodeReviewCounts(r.findings))
        let none = CodeReviewCounts([])
        XCTAssertEqual(none.total, 0)
        XCTAssertNotEqual(none.line, c.line)
        XCTAssertNotEqual(CodeReviewCounts([finding(#"{"id":1}"#)!]).line, CodeReviewCounts([finding(#"{"id":1,"shouldFix":"fix"}"#)!]).line)
    }

    // MARK: - What a pull request still carries

    func testLatestFindingsAreTheNewestCompletedReviews() {
        let reviews = CodeReview.parse(j(#"""
        {"codeReviews":[{"id":3,"status":"running","findings":[]},
                        {"id":2,"status":"completed","findings":[{"id":20},{"id":21}]},
                        {"id":1,"status":"completed","findings":[{"id":10}]}]}
        """#))
        XCTAssertEqual(reviews.latestFindings.map(\.id), [20, 21])
        XCTAssertEqual(Array(reviews.suffix(1)).latestFindings.map(\.id), [10])
        XCTAssertEqual([CodeReview]().latestFindings, [])
        let clean = CodeReview.parse(j(#"{"codeReviews":[{"id":2,"status":"completed","findings":[]},{"id":1,"status":"completed","findings":[{"id":10}]}]}"#))
        XCTAssertEqual(clean.latestFindings, [])
        let running = CodeReview.parse(j(#"{"codeReviews":[{"id":1,"status":"running","findings":[{"id":10}]}]}"#))
        XCTAssertEqual(running.latestFindings.map(\.id), [10])
        XCTAssertEqual(CodeReview.parse(j(#"{"codeReviews":[{"id":1,"findings":[]}]}"#)).latestFindings, [])
    }

    func testAHandledReviewStillCarriesItsFindings() {
        // Handling is a person's note on the review; what it found is still what CarPlay and the voice read.
        let handled = CodeReview.parse(j(#"{"codeReviews":[{"id":2,"status":"completed","handlingStatus":"handled","findings":[{"id":20}]}]}"#))
        XCTAssertEqual(handled.latestFindings.map(\.id), [20])
    }

    // MARK: - Handling

    func testHandlingIsReadAndAbsentFromAServerThatDoesNotTrackIt() {
        XCTAssertEqual(review(#"{"id":1,"status":"completed","handlingStatus":"handled"}"#)?.handling, .handled)
        XCTAssertEqual(review(#"{"id":1,"status":"completed","handlingStatus":"pending"}"#)?.handling, .pending)
        XCTAssertNil(review(#"{"id":1,"status":"completed"}"#)?.handling)
        XCTAssertNil(review(#"{"id":1,"status":"completed","handlingStatus":"done"}"#)?.handling)
        XCTAssertNotEqual(CodeReviewHandling.handled.tone, CodeReviewHandling.pending.tone)
    }

    func testOnlyAStoppedReviewOnAServerThatTracksHandlingCanChangeIt() {
        XCTAssertEqual(review(#"{"id":1,"status":"completed","handlingStatus":"pending"}"#)!.handlingAction, .markHandled)
        XCTAssertEqual(review(#"{"id":1,"status":"failed","handlingStatus":"handled"}"#)!.handlingAction, .reopen)
        XCTAssertNil(review(#"{"id":1,"status":"running","handlingStatus":"pending"}"#)!.handlingAction)
        XCTAssertNil(review(#"{"id":1,"status":"completed"}"#)!.handlingAction)
        XCTAssertTrue(CodeReviewHandlingAction.markHandled.handles); XCTAssertFalse(CodeReviewHandlingAction.reopen.handles)
        XCTAssertNotEqual(CodeReviewHandlingAction.markHandled.symbol, CodeReviewHandlingAction.reopen.symbol)
        XCTAssertTrue(review(#"{"id":1,"status":"completed"}"#)!.canEditFindings)
        XCTAssertFalse(review(#"{"id":1,"status":"running"}"#)!.canEditFindings)
    }

    func testMarkingHandledSendsOnlyWhatTheRouteTakes() throws {
        let r = review(#"{"id":5,"repo":"O/R","status":"completed","handlingStatus":"pending"}"#)!
        let a = r.handlingArguments(repo: "o/r", number: 9, .markHandled)
        XCTAssertEqual(a.count, 4)
        XCTAssertEqual(a["repo"].string, "o/r"); XCTAssertEqual(a["pr"].int, 9); XCTAssertEqual(a["reviewId"].int, 5)
        XCTAssertEqual(a["handlingStatus"].string, "handled")
        XCTAssertEqual(r.handlingArguments(repo: "o/r", number: 9, .reopen)["handlingStatus"].string, "pending")
        // The pull request and review go in the path; the server refuses any body field but these.
        let (path, rest) = try APIClient.resolve(try XCTUnwrap(APIRoute.named("update_code_review")), a)
        XCTAssertEqual(path, "pulls/9/code-reviews/5")
        XCTAssertEqual(Set(rest.keys), ["repo", "handlingStatus"])
    }

    // MARK: - Folding an answer back in

    private var list: JSON {
        j(#"""
        [{"id":2,"status":"completed","handlingStatus":"pending","findings":[{"id":20,"shouldFix":"fix"},{"id":21}]},
         {"id":1,"status":"completed","handlingStatus":"pending","findings":[{"id":10,"shouldFix":"fix"}]}]
        """#)
    }

    func testAnUpdatedReviewTakesItsOwnPlace() {
        let answer = j(#"{"id":1,"status":"completed","handlingStatus":"handled","findings":[{"id":10,"shouldFix":"fix"}]}"#)
        let after = CodeReview.parse(["codeReviews": CodeReview.replacing(review: answer, in: list)])
        XCTAssertEqual(after.map(\.id), [2, 1])
        XCTAssertEqual(after.map(\.handling), [.pending, .handled])
        XCTAssertEqual(after[1].findings.map(\.id), [10])
        // A review the list does not hold, or an answer without an id, leaves it as it was.
        XCTAssertEqual(CodeReview.replacing(review: j(#"{"id":9,"handlingStatus":"handled"}"#), in: list), list)
        XCTAssertEqual(CodeReview.replacing(review: j(#"{"handlingStatus":"handled"}"#), in: list), list)
    }

    func testAnUpdatedFindingTakesItsPlaceInItsOwnReviewOnly() {
        let answer = j(#"{"id":21,"shouldFix":"dismiss","comments":"Guarded upstream."}"#)
        let after = CodeReview.parse(["codeReviews": CodeReview.replacing(finding: answer, inReview: 2, in: list)])
        XCTAssertEqual(after[0].findings.map(\.id), [20, 21])
        XCTAssertEqual(after[0].findings.map(\.verdict), [.fix, .dismiss])
        XCTAssertEqual(after[0].findings[1].comments, "Guarded upstream.")
        XCTAssertEqual(after[1].findings.map(\.verdict), [.fix])
        // Another review, or one the list does not hold, is left alone.
        XCTAssertEqual(CodeReview.replacing(finding: answer, inReview: 1, in: list), list)
        XCTAssertEqual(CodeReview.replacing(finding: answer, inReview: 7, in: list), list)
    }

    // MARK: - Overruling a verdict

    func testAnEditStartsCleanAndSendsOnlyWhatChanged() throws {
        let f = finding(#"{"id":21,"shouldFix":"fix","comments":"  Reproduced. "}"#)!
        var e = CodeReviewFindingEdit(f, review: 2)
        XCTAssertFalse(e.isDirty); XCTAssertFalse(e.canSave)
        e.reason = "Reproduced."
        XCTAssertFalse(e.isDirty)
        e.verdict = .optional
        XCTAssertTrue(e.isDirty)
        // The verify step's reason for fixing it cannot stand as the reason for not fixing it.
        XCTAssertFalse(e.canSave)
        var a = e.arguments(repo: "o/r", number: 9)
        XCTAssertEqual(a.count, 5)
        XCTAssertEqual(a["pr"].int, 9); XCTAssertEqual(a["reviewId"].int, 2); XCTAssertEqual(a["findingId"].int, 21)
        XCTAssertEqual(a["shouldFix"].string, "optional")
        XCTAssertNil(a.object?["comments"])
        e.reason = " Not worth it here. \n"
        XCTAssertTrue(e.canSave)
        a = e.arguments(repo: "o/r", number: 9)
        XCTAssertEqual(a.count, 6); XCTAssertEqual(a["comments"].string, "Not worth it here.")
        let (path, rest) = try APIClient.resolve(try XCTUnwrap(APIRoute.named("update_code_review_finding")), a)
        XCTAssertEqual(path, "pulls/9/code-reviews/2/findings/21")
        XCTAssertEqual(Set(rest.keys), ["repo", "shouldFix", "comments"])
    }

    func testEveryVerdictIsAChoiceAndNoneComesLast() {
        XCTAssertEqual(CodeReviewVerdict.choices, [.fix, .optional, .dismiss, nil])
        XCTAssertEqual(Set(CodeReviewVerdict.choices.map(CodeReviewVerdict.choiceTitle)).count, CodeReviewVerdict.choices.count)
    }

    func testNotFixingAFindingNeedsAReason() {
        var e = CodeReviewFindingEdit(finding(#"{"id":1,"shouldFix":"fix"}"#)!, review: 1)
        for verdict in [CodeReviewVerdict.optional, .dismiss] {
            e.verdict = verdict; e.reason = " "
            XCTAssertTrue(e.needsReason); XCTAssertFalse(e.canSave)
            e.reason = "Refuted by the guard on line 4."
            XCTAssertTrue(e.canSave)
        }
        let asksWhyNotFixed = e.reasonPrompt
        e.verdict = nil; e.reason = ""
        XCTAssertFalse(e.needsReason); XCTAssertTrue(e.canSave)
        XCTAssertNotEqual(e.reasonPrompt, asksWhyNotFixed)
    }

    func testANewVerdictNotToFixNeedsAReasonOfItsOwn() {
        let saved = finding(#"{"id":1,"shouldFix":"optional","comments":"Not worth it."}"#)!
        var e = CodeReviewFindingEdit(saved, review: 1)
        XCTAssertNil(CodeReviewFindingEdit(finding(#"{"id":1,"shouldFix":"fix"}"#)!, review: 1).reasonHint)
        XCTAssertNotNil(e.reasonHint)
        // The same verdict keeps its reason: rewording it is enough.
        e.reason = "Not worth it here."
        XCTAssertTrue(e.hasReason); XCTAssertTrue(e.canSave)
        // A changed verdict needs a reason other than the saved one, even one only spaced differently.
        e.verdict = .dismiss; e.reason = " Not worth it. "
        XCTAssertFalse(e.hasReason); XCTAssertFalse(e.canSave)
        e.reason = "Refuted: the guard on line 4 covers it."
        XCTAssertTrue(e.canSave)
        // Back to Fix, the saved reason may stay.
        e.verdict = .fix; e.reason = "Not worth it."
        XCTAssertTrue(e.canSave)
    }

    func testAReadHoldsOnlyWhenNoWriteBeganOrEndedSinceItStarted() {
        var marks = WriteMarks()
        XCTAssertTrue(marks.holds(nil))
        let before = marks.mark
        XCTAssertTrue(marks.holds(before))
        marks.begin()
        let during = marks.mark
        XCTAssertFalse(marks.holds(before))
        XCTAssertTrue(marks.holds(during))
        marks.end()
        XCTAssertFalse(marks.holds(before)); XCTAssertFalse(marks.holds(during))
        XCTAssertTrue(marks.holds(marks.mark)); XCTAssertTrue(marks.holds(nil))
    }

    func testAVerdictIsSavedOnlyWhileItsReviewHasStopped() {
        func reviews(_ status: String) -> [CodeReview] {
            CodeReview.parse(j(#"{"codeReviews":[{"id":4,"status":"\#(status)","findings":[{"id":7,"title":"T"}]}]}"#))
        }
        var edit = CodeReviewFindingEdit(reviews("completed")[0].findings[0], review: 4)
        XCTAssertFalse(reviews("completed").allowsSaving(edit))
        edit.verdict = .fix
        XCTAssertTrue(reviews("completed").allowsSaving(edit))
        XCTAssertTrue(reviews("failed").allowsSaving(edit))
        XCTAssertFalse(reviews("running").allowsSaving(edit))
        XCTAssertFalse([CodeReview]().allowsSaving(edit))
    }

    func testClearingAVerdictOrAReasonSendsNull() {
        var e = CodeReviewFindingEdit(finding(#"{"id":3,"shouldFix":"dismiss","comments":"Refuted."}"#)!, review: 1)
        e.verdict = nil; e.reason = ""
        let a = e.arguments(repo: "o/r", number: 9)
        XCTAssertEqual(a.object?["shouldFix"], JSON.null)
        XCTAssertEqual(a.object?["comments"], JSON.null)
    }
}

final class CodeReviewRouteTests: XCTestCase {
    func testCodeReviewsAreReadOnTheirOwnRouteAndTheFindingsRoutesAreGone() {
        XCTAssertEqual(APIRoute.named("code_reviews")?.method, "GET")
        XCTAssertEqual(APIRoute.named("code_reviews")?.path, "pulls/{pr}/code-reviews")
        XCTAssertEqual(APIRoute.named("update_code_review")?.method, "PATCH")
        XCTAssertEqual(APIRoute.named("update_code_review_finding")?.method, "PATCH")
        for gone in ["findings", "finding_decision", "review", "review_loop", "complete_findings", "save_findings", "reply_finding", "delete_finding"] {
            XCTAssertNil(APIRoute.named(gone), gone)
        }
    }
}

final class CodeReviewSessionTests: XCTestCase {
    func testOnlyARunningReviewOffersItsSessionWhichTheServerDeletesOnClose() {
        func review(_ status: String, _ session: String? = "s1") -> CodeReview {
            var j: JSON = ["id": 1, "status": .string(status)]
            if let session { j["sessionId"] = .string(session) }
            return CodeReview(j)!
        }
        XCTAssertEqual(review("running").openableSessionID, "s1")
        XCTAssertNil(review("completed").openableSessionID)
        XCTAssertNil(review("failed").openableSessionID)
        XCTAssertNil(review("running", nil).openableSessionID)
    }
}
