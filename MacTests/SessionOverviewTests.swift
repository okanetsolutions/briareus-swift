// The overview of what waits for you and what is working: each conversation's state, the counts, and the question left up.
import XCTest
@testable import BriareusMacCore

final class SessionOverviewTests: XCTestCase {
    private func sessions(_ text: String) -> [Session] { Session.parseList(j(text)) ?? [] }

    func testStateReadsAQuestionThenHeldFindingsThenTheStatus() {
        let list = sessions(#"""
        [{"id":"a","status":"idle","awaitingAnswer":true,"reviewTriage":{"findings":[{}]}},
         {"id":"b","status":"idle","reviewTriage":{"findings":[]}},
         {"id":"c","status":"idle","reviewLoop":{"triage":{"findings":[{}]}}},
         {"id":"d","status":"running","awaitingAnswer":true},
         {"id":"e","status":"queued"},{"id":"f","status":"starting"},
         {"id":"g","status":"idle"},{"id":"h","status":"failed"},{"id":"i","status":"closed"},{"id":"k","status":"interrupted"}]
        """#)
        XCTAssertEqual(list.map(\.state), [.waiting, .findings, .findings, .working, .working, .working, .ready, .failed, .closed, .closed])
        XCTAssertEqual(list.map(\.state.needsYou), [true, true, true, false, false, false, false, false, false, false])
        XCTAssertEqual(SessionState.waiting.label, "Needs your answer")
        XCTAssertEqual(SessionState.ready.label, "Ready")
    }

    func testOverviewCountsTopLevelConversationsOnly() {
        let o = SessionOverview(sessions(#"""
        [{"id":"w1","status":"idle","awaitingAnswer":true,"endedAt":"2026-01-02T00:00:00Z"},
         {"id":"f1","status":"idle","reviewTriage":{"findings":[]},"endedAt":"2026-01-01T00:00:00Z"},
         {"id":"w2","status":"idle","awaitingAnswer":true,"createdAt":"2026-01-03T00:00:00Z"},
         {"id":"worker","status":"idle","awaitingAnswer":true,"parentId":"o1"},
         {"id":"r1","status":"running","title":"beta"},{"id":"r2","status":"preparing","title":"Alpha"},
         {"id":"r3","status":"running","parentId":"o1"},
         {"id":"i1","status":"idle"},{"id":"i2","status":"idle","parentId":""},{"id":"c1","status":"closed"}]
        """#))
        // Longest waiting first; a worker with a parent is left out, an empty parent is no parent.
        XCTAssertEqual(o.needingYou.map(\.id), ["f1", "w1", "w2"])
        XCTAssertEqual(o.working.map(\.id), ["r2", "r1"])
        XCTAssertEqual(o.needsYouCount, 3)
        XCTAssertEqual(o.workingCount, 2)
        XCTAssertEqual(o.ready, 2)
        XCTAssertFalse(o.quiet)
        XCTAssertTrue(SessionOverview(sessions(#"[{"id":"a","status":"idle"},{"id":"b","status":"closed"}]"#)).quiet)
    }

    func testPendingQuestionUntilAMessageAnswersIt() {
        var t = Transcript()
        XCTAssertNil(t.pendingQuestion)
        t.append(j(#"[{"seq":1,"kind":"ask","question":"Which?","options":[{"label":"A"},{"label":"B"},{},{"label":""}]},{"seq":2,"kind":"status","text":"idle"}]"#))
        XCTAssertEqual(t.pendingQuestion, PendingQuestion(text: "Which?", options: ["A", "B"]))
        t.append(j(#"[{"seq":3,"kind":"user","text":"A"}]"#))
        XCTAssertNil(t.pendingQuestion)
        // A later question with no options, asked in its text.
        t.append(j(#"[{"seq":4,"kind":"ask","text":"Go on?"}]"#))
        XCTAssertEqual(t.pendingQuestion, PendingQuestion(text: "Go on?", options: []))
    }
}
