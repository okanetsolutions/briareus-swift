// The issue page's own logic (Mac/Core/IssuePage.swift): its state pill, its open linked pull requests, and its timeline's
// events as the Windows client words them (screen_pulls.c, which has no C tests of its own for them).
import XCTest
@testable import BriareusMacCore

final class IssuePageTests: XCTestCase {
    private func words(_ text: String, repo: String? = "o/r") -> String? {
        timelineEventWords(j(text), repo: repo).map { $0.parts.map(\.text).joined() }
    }

    func testTheStatePillFollowsTheIssuesOwnRead() {
        XCTAssertEqual(IssuePageState(detail: .null, closedHere: false, closedReason: nil, gone: false), .open)
        // Off the board and not read on its own: it may well be closed.
        XCTAssertEqual(IssuePageState(detail: .null, closedHere: false, closedReason: nil, gone: true), .offBoard)
        XCTAssertEqual(IssuePageState(detail: j(#"{"state":"open"}"#), closedHere: false, closedReason: nil, gone: true), .open)
        XCTAssertEqual(IssuePageState(detail: j(#"{"state":"closed","stateReason":"completed"}"#), closedHere: false, closedReason: nil, gone: false), .closed)
        XCTAssertEqual(IssuePageState(detail: j(#"{"state":"closed","stateReason":"duplicate"}"#), closedHere: false, closedReason: nil, gone: false), .closedAside)
        // Closing it here outweighs a read from before.
        let s = IssuePageState(detail: j(#"{"state":"open"}"#), closedHere: true, closedReason: "not_planned", gone: false)
        XCTAssertEqual(s, .closedAside); XCTAssertTrue(s.isClosed); XCTAssertEqual(s.text, "closed")
        XCTAssertEqual(IssuePageState.offBoard.text, "not on the board"); XCTAssertFalse(IssuePageState.offBoard.isClosed)
    }

    func testOnlyOpenLinkedPullRequestsCount() {
        let issue = IssueSummary(j(#"{"number":4,"pulls":[{"number":1},{"number":2,"state":"open"},{"number":3,"state":"merged"},{"number":5,"state":"closed"}]}"#))!
        XCTAssertEqual(issueOpenPulls(issue), 2)
        XCTAssertEqual(issueOpenPulls(IssueSummary(j(#"{"number":4}"#))!), 0)
    }

    func testTimelineEventsReadAsGitHubWordsThem() {
        XCTAssertEqual(words(#"{"kind":"labeled","label":{"name":"bug"}}"#), "added the buglabel ")
        XCTAssertEqual(words(#"{"kind":"assigned","actor":"Ana","assignee":"ana"}"#), "self-assigned this ")
        XCTAssertEqual(words(#"{"kind":"assigned","actor":"ana","assignee":"bo"}"#), "assigned bo ")
        XCTAssertEqual(words(#"{"kind":"unassigned","actor":"ana","assignee":"ana"}"#), "removed their assignment ")
        XCTAssertEqual(words(#"{"kind":"renamed","from":"Old","to":"New"}"#), "changed the title \u{201C}Old\u{201D} to \u{201C}New\u{201D} ")
        XCTAssertEqual(words(#"{"kind":"closed","stateReason":"not_planned"}"#), "closed this as not planned ")
        XCTAssertEqual(words(#"{"kind":"closed"}"#), "closed this ")
        XCTAssertEqual(words(#"{"kind":"cross-referenced","source":{"number":7,"title":"Fix it","repo":"o/r"}}"#), "mentioned this in #7 Fix it ")
        XCTAssertEqual(words(#"{"kind":"connected","source":{"number":7,"title":"Fix","repo":"a/b"}}"#),
                       "linked a pull request that will close this issue a/b#7 Fix ")
        XCTAssertEqual(words(#"{"kind":"referenced","commit":{"sha":"abcdef0123","message":"Tidy"}}"#), "referenced this in commit abcdef0Tidy ")
        XCTAssertEqual(words(#"{"kind":"issue_type_changed","previousType":"Bug","type":"Feature"}"#), "changed the issue type from Bug to Feature ")
        XCTAssertEqual(words(#"{"kind":"project_v2_item_status_changed","project":"Roadmap","previousStatus":"Todo","status":"Done"}"#),
                       "moved this from Todo to Done in Roadmap ")
        XCTAssertEqual(words(#"{"kind":"project_v2_item_status_changed"}"#), "moved this to No status ")
        XCTAssertEqual(words(#"{"kind":"added_to_project_v2"}"#), "added this to a project ")
        // Comments are drawn as boxes, and kinds this app does not know are left out.
        XCTAssertNil(words(#"{"kind":"commented","body":"hi"}"#))
        XCTAssertNil(words(#"{"kind":"subscribed"}"#))
    }

    func testTimelineEventsCarryTheirBadges() {
        var w = timelineEventWords(j(#"{"kind":"closed","stateReason":"duplicate"}"#), repo: nil)!
        XCTAssertEqual(w.glyph, 0xE711); XCTAssertEqual(w.tone, .muted)
        w = timelineEventWords(j(#"{"kind":"closed","stateReason":"completed"}"#), repo: nil)!
        XCTAssertEqual(w.glyph, 0xE73E); XCTAssertEqual(w.tone, .accent)
        w = timelineEventWords(j(#"{"kind":"reopened"}"#), repo: nil)!
        XCTAssertEqual(w.glyph, 0xE72C); XCTAssertEqual(w.tone, .ok)
        w = timelineEventWords(j(#"{"kind":"labeled","label":{"name":"ui"}}"#), repo: nil)!
        XCTAssertEqual(w.glyph, 0xE8EC); XCTAssertEqual(w.parts[1], TimelinePart(text: "ui", style: .label))
    }

    func testTimelineEventsOpenWhatTheyPointTo() {
        XCTAssertTrue(timelineEventHasTarget(j(#"{"kind":"commented","url":"https://github.com/o/r/issues/1#c"}"#)))
        XCTAssertFalse(timelineEventHasTarget(j(#"{"kind":"commented","url":"http://x"}"#)))
        XCTAssertTrue(timelineEventHasTarget(j(#"{"kind":"cross-referenced","source":{"number":3}}"#)))
        XCTAssertTrue(timelineEventHasTarget(j(#"{"kind":"sub_issue_added","issue":{"number":3}}"#)))
        XCTAssertTrue(timelineEventHasTarget(j(#"{"kind":"referenced","commit":{"url":"https://github.com/o/r/commit/abc"}}"#)))
        XCTAssertFalse(timelineEventHasTarget(j(#"{"kind":"labeled","label":{"name":"x"}}"#)))
    }
}
