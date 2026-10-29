// A pull request's code reviews (Mac/Core/CodeReviewLogic.swift): what `GET /pulls/{number}/code-reviews` answers, read
// into reviews and findings, with their verdicts, places, counts and the findings a pull request still carries.
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
}

final class CodeReviewRouteTests: XCTestCase {
    func testCodeReviewsAreReadOnTheirOwnRouteAndTheFindingsRoutesAreGone() {
        XCTAssertEqual(APIRoute.named("code_reviews")?.method, "GET")
        XCTAssertEqual(APIRoute.named("code_reviews")?.path, "pulls/{pr}/code-reviews")
        for gone in ["findings", "finding_decision", "review", "review_loop", "complete_findings", "save_findings", "reply_finding", "delete_finding"] {
            XCTAssertNil(APIRoute.named(gone), gone)
        }
    }
}
