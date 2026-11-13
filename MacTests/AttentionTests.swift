// The operator's attention list (core lib/attention.js): approvals carry their request; kinds the app has no word for pass through.
import XCTest
@testable import BriareusMacCore

final class AttentionTests: XCTestCase {
    func testItemsReadApprovalsAndKeepKindsTheAppDoesNotKnow() {
        var list = AttentionItem.parse(j(#"{"items":[{"id":"ssh:r1","kind":"ssh","title":"web-1","repo":"o/heedly","sessionId":"s1","sessionTitle":"Fix checks","summary":"php artisan migrate","at":"2026-10-08T14:00:00.123Z","request":{"id":"r1","username":"deploy","host":"10.0.0.5","port":22,"expiresAt":1791400000000,"unattended":true}},{"id":"s2:findings","kind":"findings","title":"Review"},{"id":"slack:q1","kind":"slack","title":"Slack to #deploys","summary":"Deployed","request":{"id":"q1","workspaceLabel":"HQ","sendsAs":"nadin"}},{"id":"s3:question","kind":"question","title":"Implement","summary":"Which database?","sessionId":"s3","at":"2026-10-08T13:00:00Z"},{"kind":"broken"}]}"#))
        // The server no longer sends findings; one that still says so is kept like any kind the app does not know.
        XCTAssertEqual(list.map(\.id), ["ssh:r1", "s2:findings", "slack:q1", "s3:question"])
        XCTAssertEqual(list[1].label, "findings"); XCTAssertFalse(list[1].isApproval)
        list.remove(at: 1)
        let ssh = list[0]
        XCTAssertTrue(ssh.isApproval); XCTAssertEqual(ssh.requestID, "r1"); XCTAssertEqual(ssh.label, "SSH approval")
        XCTAssertEqual(ssh.detail, "o/heedly · Fix checks · deploy@10.0.0.5:22 · asked in a turn nobody started")
        XCTAssertEqual(ssh.expiresAt, Date(timeIntervalSince1970: 1791400000))
        XCTAssertNotNil(ssh.at)
        XCTAssertFalse(ssh.elevated)
        XCTAssertEqual(list[1].detail, "as nadin in HQ")
        XCTAssertFalse(list[2].isApproval); XCTAssertEqual(list[2].label, "Question"); XCTAssertEqual(list[2].sessionID, "s3")
        XCTAssertNotNil(list[2].at)
    }

    func testSudoApprovalsAreElevated() {
        let list = AttentionItem.parse(j(#"{"items":[{"id":"ssh:r2","kind":"ssh","title":"web-1","request":{"id":"r2","username":"deploy","host":"h","sudo":true}},{"id":"slack:q1","kind":"slack","title":"Slack","request":{"id":"q1","sudo":true}}]}"#))
        XCTAssertTrue(list[0].elevated)
        XCTAssertNotEqual(list[0].detail, AttentionItem.parse(j(#"{"items":[{"id":"ssh:r2","kind":"ssh","title":"web-1","request":{"id":"r2","username":"deploy","host":"h"}}]}"#))[0].detail)
        XCTAssertFalse(list[1].elevated)
    }

    func testAReviewItemWithoutASessionOpensItsPullRequest() {
        let list = AttentionItem.parse(j(#"{"items":[{"id":"review-limit:o/r#7","kind":"review-limit","repo":"o/r","prNumber":7,"sessionId":null,"taskId":null,"title":"PR #7","summary":"3 of 3 rounds used"},{"id":"review-approval:o/r#8","kind":"review-approval","repo":"o/r","prNumber":8,"title":"PR #8"},{"id":"s3:question","kind":"question","repo":"o/r","prNumber":9,"sessionId":"s3","title":"Implement"},{"id":"review-status:x#1","kind":"review-status","prNumber":1,"title":"PR #1"}]}"#))
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list[0].pull?.repo, "o/r"); XCTAssertEqual(list[0].pull?.number, 7); XCTAssertNil(list[0].sessionID)
        XCTAssertEqual(list[1].pull?.number, 8)
        // An item with a session opens the session; one without a project cannot open a pull request.
        XCTAssertNil(list[2].pull)
        XCTAssertNil(list[3].pull)
        // Each review kind has a word of its own, not the raw kind.
        for item in [list[0], list[1], list[3]] { XCTAssertNotEqual(item.label, item.kind); XCTAssertFalse(item.isApproval) }
    }

    func testOnlyAReviewApprovalWithAPullRequestIsApprovedInPlace() {
        let list = AttentionItem.parse(j(#"{"items":[{"id":"review-limit:o/r#7","kind":"review-limit","repo":"o/r","prNumber":7,"title":"PR #7"},{"id":"review-approval:o/r#8","kind":"review-approval","repo":"o/r","prNumber":8,"title":"PR #8"},{"id":"review-approval:x#2","kind":"review-approval","prNumber":2,"title":"PR #2"},{"id":"review-approval:o/r#9","kind":"review-approval","repo":"o/r","prNumber":9,"sessionId":"s9","title":"PR #9"},{"id":"ssh:r1","kind":"ssh","repo":"o/r","prNumber":8,"title":"web-1","request":{"id":"r1"}}]}"#))
        XCTAssertNil(list[0].approvalPull)
        XCTAssertEqual(list[1].approvalPull?.repo, "o/r"); XCTAssertEqual(list[1].approvalPull?.number, 8)
        // Without a project, or tied to a session, there is no pull request to read; another kind never is one.
        XCTAssertNil(list[2].approvalPull)
        XCTAssertNil(list[3].approvalPull)
        XCTAssertNil(list[4].approvalPull)
        XCTAssertEqual(AttentionItem.approvalPulls(list).map(\.id), ["review-approval:o/r#8"])
    }
}
