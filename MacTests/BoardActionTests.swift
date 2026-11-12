// Ported from the Windows client's tests/core_board_tests.c: the errands a pull request is offered, what each one sends,
// and the extra round a code review asks for past the round limit (BoardAction.swift).
import XCTest
@testable import BriareusMacCore

final class BoardActionTests: XCTestCase {
    private func pull(_ text: String) -> PullSummary? { PullSummary(j(text)) }

    private func ids(_ a: [BoardAction]) -> String { a.map(\.id).joined(separator: ",") }
    private func offered(_ catalog: String?, _ pullText: String?, _ failedChecks: Int) -> String {
        ids(BoardAction.offered(catalog: catalog.map { j($0) } ?? .null, pull: pullText.flatMap(pull), failedChecks: failedChecks))
    }
    private func known(_ id: String) -> BoardAction? { BoardAction.known.first { $0.id == id } }

    func testKnownErrandsAreListedInOrder() {
        let k = BoardAction.known
        XCTAssertEqual(ids(k), "run,review,solve-conflicts,fix-checks,implement-feedback,test-sheet,test-run,pr-body-summary,delete-self-comments")
        for a in k { XCTAssertFalse(a.label.isEmpty); XCTAssertFalse(a.hint.isEmpty); XCTAssertNil(a.input); XCTAssertNil(a.binary) }
        XCTAssertEqual(known("run")?.label, "Run"); XCTAssertEqual(known("review")?.label, "Code review")
        XCTAssertEqual(known("test-sheet")?.label, "Test sheet"); XCTAssertEqual(known("test-run")?.label, "Record QA")
        // QA as an errand of its own was removed (#12) and custom feedback went with the findings system; the server brought
        // Implement feedback back as a plain errand.
        for gone in ["qa", "custom-feedback"] { XCTAssertNil(known(gone), gone) }
    }
    func testErrandsStartThroughTheirOwnOperation() {
        // Every errand but Run goes through `action`, Code review included.
        for a in BoardAction.known {
            XCTAssertEqual(a.operation, a.id == "run" ? "serve_pull" : "action")
            XCTAssertEqual(a.timeoutMs, a.id == "run" ? 170_000 : nil)
        }
        let served = BoardAction(id: "label-pull", label: "Label it")
        XCTAssertEqual(served.operation, "action"); XCTAssertNil(served.timeoutMs)
    }
    func testErrandArgumentsTakeTheShapeEachRouteWants() {
        var a = known("run")!.arguments(repo: "o/r", number: 9, input: "ignored")
        XCTAssertEqual(a.count, 2); XCTAssertEqual(a["repo"].string, "o/r"); XCTAssertEqual(a["prNumber"].int, 9)
        XCTAssertTrue(a["branch"].isNull); XCTAssertTrue(a["action"].isNull)
        for errand in ["review", "solve-conflicts", "fix-checks", "implement-feedback", "pr-body-summary", "delete-self-comments"] {
            // Errands look the pull request up by number, so no branch is sent, nor input they do not take.
            a = known(errand)!.arguments(repo: "o/r", number: 9, input: "text")
            XCTAssertEqual(a.count, 3); XCTAssertEqual(a["action"].string, errand)
            XCTAssertTrue(a["branch"].isNull); XCTAssertTrue(a["input"].isNull)
        }
        let asks = BoardAction(id: "explain", label: "Explain", input: ActionInput(label: "What?", placeholder: "", required: true))
        a = asks.arguments(repo: "o/r", number: 9, input: "\t Use 404 \r\n")
        XCTAssertEqual(a.count, 4); XCTAssertEqual(a["action"].string, "explain"); XCTAssertEqual(a["input"].string, "Use 404")
        a = asks.arguments(repo: "o/r", number: 9, input: " \n\t ")
        XCTAssertEqual(a.count, 3); XCTAssertTrue(a["input"].isNull)
        XCTAssertEqual(asks.arguments(repo: "o/r", number: 9).count, 3)
        XCTAssertEqual(asks.arguments(repo: "o/r", number: 9, input: "line one\nline two")["input"].string, "line one\nline two")
    }
    func testOnlyAReviewAsksForAnotherRound() {
        XCTAssertNil(known("review")!.arguments(repo: "o/r", number: 9).object?["continueReview"])
        XCTAssertEqual(known("review")!.arguments(repo: "o/r", number: 9, continueReview: true)["continueReview"], true)
        // Any other errand would be refused with it.
        XCTAssertNil(known("fix-checks")!.arguments(repo: "o/r", number: 9, continueReview: true).object?["continueReview"])
    }

    func testTheAnotherRoundQuestionKeepsWhatTheServerSaid() {
        XCTAssertTrue(BoardAction.anotherRoundQuestion(APIError(.http, status: 409, message: "2 fixes unresolved.")).hasPrefix("2 fixes unresolved."))
        XCTAssertFalse(BoardAction.anotherRoundQuestion(APIError(.http, status: 409)).isEmpty)
    }

    func testErrandsAreOfferedForTheStateAPullRequestIsIn() {
        let always = "run,review,test-sheet,test-run,pr-body-summary,delete-self-comments"
        XCTAssertEqual(offered(nil, #"{"number":1,"mergeable":"mergeable","checks":"success"}"#, 0), always)
        // A draft is offered the same errands; a pull request awaiting feedback is offered implementing it.
        XCTAssertEqual(offered(nil, #"{"number":1,"draft":true}"#, 0), always)
        XCTAssertEqual(offered(nil, #"{"number":1,"labels":["FEEDBACK-GIVEN"]}"#, 0), "run,review,implement-feedback,test-sheet,test-run,pr-body-summary,delete-self-comments")
        XCTAssertEqual(offered(nil, #"{"number":1,"mergeable":"conflicting"}"#, 0), "run,review,solve-conflicts,test-sheet,test-run,pr-body-summary,delete-self-comments")
        XCTAssertEqual(offered(nil, #"{"number":1,"labels":["Has-Conflicts"]}"#, 0), "run,review,solve-conflicts,test-sheet,test-run,pr-body-summary,delete-self-comments")
        XCTAssertEqual(offered(nil, #"{"number":1,"checks":"error"}"#, 0), "run,review,fix-checks,test-sheet,test-run,pr-body-summary,delete-self-comments")
        // A run still going has nothing to fix; a count of failed checks from the Checks tab outweighs the summary.
        XCTAssertEqual(offered(nil, #"{"number":1,"checks":"pending"}"#, 0), always)
        XCTAssertEqual(offered(nil, #"{"number":1,"checks":"success"}"#, 2), "run,review,fix-checks,test-sheet,test-run,pr-body-summary,delete-self-comments")
        XCTAssertEqual(offered(nil, #"{"number":1}"#, -1), always)
        // Without a pull request, everything but fixing checks nobody has seen fail.
        XCTAssertEqual(offered(nil, nil, 0), "run,review,solve-conflicts,implement-feedback,test-sheet,test-run,pr-body-summary,delete-self-comments")
        XCTAssertEqual(offered(nil, nil, 1), "run,review,solve-conflicts,fix-checks,implement-feedback,test-sheet,test-run,pr-body-summary,delete-self-comments")
    }
    func testAKnownCatalogRestrictsErrandsToThoseItLists() {
        let conflicted = #"{"number":1,"mergeable":"conflicting","checks":"failure","labels":["feedback-given"]}"#
        let all = "run,review,solve-conflicts,fix-checks,implement-feedback,test-sheet,test-run,pr-body-summary,delete-self-comments"
        // An empty catalog, or one with nothing readable in it, is not known yet.
        XCTAssertEqual(offered("[]", conflicted, 0), all)
        XCTAssertEqual(offered(#"[{"id":"pr-body-summary"},{"label":"x"},"y"]"#, conflicted, 0), all)
        XCTAssertEqual(offered(#"{"id":"pr-body-summary","label":"PR body"}"#, #"{"number":1}"#, 0), "run,review,test-sheet,test-run,pr-body-summary,delete-self-comments")
        // Only Run has a route of its own; Code review has to be listed like any errand.
        XCTAssertEqual(offered(#"[{"id":"pr-body-summary","label":"PR body"}]"#, conflicted, 0), "run,pr-body-summary")
        XCTAssertEqual(offered(#"[{"id":"review","label":"R"},{"id":"pr-body-summary","label":"PR body"}]"#, conflicted, 0), "run,review,pr-body-summary")
        // Listed is not enough: the pull request has to be in the state for it.
        XCTAssertEqual(offered(#"[{"id":"solve-conflicts","label":"S"},{"id":"fix-checks","label":"F"}]"#, #"{"number":1}"#, 0), "run")
        XCTAssertEqual(offered(#"[{"id":"fix-checks","label":"F"},{"id":"solve-conflicts","label":"S"}]"#, conflicted, 0), "run,solve-conflicts,fix-checks")
        XCTAssertEqual(offered(#"[{"id":"implement-feedback","label":"I"}]"#, #"{"number":1}"#, 0), "run")
        XCTAssertEqual(offered(#"[{"id":"implement-feedback","label":"I"},{"id":"solve-conflicts","label":"S"}]"#, conflicted, 0), "run,solve-conflicts,implement-feedback")
    }
    func testDroppedErrandsAreNeverOfferedEvenWhenListed() {
        let catalog = #"[{"id":"implement-feedback","label":"I"},{"id":"custom-feedback","label":"C","input":{"label":"Say"}},"#
            + #"{"id":"qa","label":"QA"},{"id":"review","label":"R"}]"#
        XCTAssertEqual(offered(catalog, #"{"number":1,"labels":["feedback-given"]}"#, 0), "run,review,implement-feedback")
    }
    func testErrandsTheAppDoesNotKnowFollowInTheServersOrder() {
        let catalog = #"[{"id":"zz-last","label":"Z"},{"id":"run","label":"Serve"},{"id":"qa","label":"QA"},{"id":"test-sheet","label":"Sheet"},"#
            + #"{"id":"test-run","label":"Run sheet"},{"id":"aa-first","label":"A","hint":"Does a","input":{"label":"Why?"}},"#
            + #"{"id":"zz-last","label":"Z again","hint":"later wins"}]"#
        var a = BoardAction.offered(catalog: j(catalog), pull: nil, failedChecks: 0)
        // QA stays gone even when the server lists it (#12); the test sheet and its run are errands the app knows.
        XCTAssertEqual(ids(a), "run,test-sheet,test-run,zz-last,aa-first")
        guard a.count == 5 else { return }
        XCTAssertEqual(a[1].label, "Test sheet"); XCTAssertEqual(a[2].label, "Record QA"); XCTAssertEqual(a[2].operation, "action")
        a.removeSubrange(1...2)
        // The app words its own errands; the server's label for one it knows is not used.
        XCTAssertEqual(a[0].label, "Run"); XCTAssertNil(a[0].input)
        XCTAssertEqual(a[1].label, "Z again"); XCTAssertEqual(a[1].hint, "later wins"); XCTAssertNil(a[1].input)
        XCTAssertEqual(a[2].label, "A"); XCTAssertEqual(a[2].hint, "Does a")
        XCTAssertEqual(a[2].input, ActionInput(label: "Why?", placeholder: "", required: false))
        XCTAssertEqual(a[2].operation, "action")
        var args = a[2].arguments(repo: "o/r", number: 4, input: " because ")
        XCTAssertEqual(args.count, 4); XCTAssertEqual(args["action"].string, "aa-first"); XCTAssertEqual(args["input"].string, "because")
        args = a[1].arguments(repo: "o/r", number: 4, input: "nothing to take it")
        XCTAssertEqual(args.count, 3); XCTAssertEqual(args["action"].string, "zz-last")
    }
    func testTheServerWordsTheQuestionAnErrandAsks() {
        let c = j(#"[{"id":"review","label":"Review","input":{"label":"Focus?","placeholder":"e.g. security","required":false}},"#
                  + #"{"id":"pr-body-summary","label":"PR body","input":{"label":"Tone?","required":true}},"#
                  + #"{"id":"delete-self-comments","label":"Delete","input":{"placeholder":"no label"}}]"#)
        let a = BoardAction.offered(catalog: c, pull: nil, failedChecks: 0)
        XCTAssertEqual(ids(a), "run,review,pr-body-summary,delete-self-comments")
        if a.count == 4 {
            XCTAssertEqual(a[1].label, "Code review")
            XCTAssertEqual(a[1].input, ActionInput(label: "Focus?", placeholder: "e.g. security", required: false))
            XCTAssertEqual(a[2].input, ActionInput(label: "Tone?", placeholder: "", required: true))
            // An input without a label is no input.
            XCTAssertNil(a[3].input)
        }
    }
    func testTheServerRestrictsAnErrandToOneCLI() {
        let c = j(#"[{"id":"review","label":"R","binary":"codex"},{"id":"pr-body-summary","label":"P","binary":""},"#
                  + #"{"id":"extra","label":"E","binary":"claude"}]"#)
        let a = BoardAction.offered(catalog: c, pull: nil, failedChecks: 0)
        XCTAssertEqual(ids(a), "run,review,pr-body-summary,extra")
        guard a.count == 4 else { return }
        // Run is not listed, so it runs anywhere; an empty binary is no restriction.
        XCTAssertNil(a[0].binary); XCTAssertNil(a[2].binary)
        XCTAssertEqual(a[1].binary, "codex"); XCTAssertEqual(a[3].binary, "claude")
        XCTAssertTrue(a[1].runs(on: "codex"))
        XCTAssertFalse(a[1].runs(on: "claude")); XCTAssertFalse(a[1].runs(on: nil))
        for binary in ["claude", "codex", nil] { XCTAssertTrue(a[2].runs(on: binary)) }
        XCTAssertEqual(BoardAction(id: "x", label: "X", binary: "grok").binary, "grok")
    }
}
