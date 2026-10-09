// The operator's attention list (core lib/attention.js): approvals carry their request, findings are left to the rounds.
import XCTest
@testable import BriareusMacCore

final class AttentionTests: XCTestCase {
    func testItemsReadApprovalsAndLeaveFindingsToTheRounds() {
        let list = AttentionItem.parse(j(#"{"items":[{"id":"ssh:r1","kind":"ssh","title":"web-1","repo":"o/heedly","sessionId":"s1","sessionTitle":"Fix checks","summary":"php artisan migrate","at":"2026-10-08T14:00:00.123Z","request":{"id":"r1","username":"deploy","host":"10.0.0.5","port":22,"expiresAt":1791400000000,"unattended":true}},{"id":"s2:findings","kind":"findings","title":"Review"},{"id":"slack:q1","kind":"slack","title":"Slack to #deploys","summary":"Deployed","request":{"id":"q1","workspaceLabel":"HQ","sendsAs":"nadin"}},{"id":"s3:question","kind":"question","title":"Implement","summary":"Which database?","sessionId":"s3","at":"2026-10-08T13:00:00Z"},{"kind":"broken"}]}"#))
        XCTAssertEqual(list.map(\.id), ["ssh:r1", "slack:q1", "s3:question"])
        let ssh = list[0]
        XCTAssertTrue(ssh.isApproval); XCTAssertEqual(ssh.requestID, "r1"); XCTAssertEqual(ssh.label, "SSH approval")
        XCTAssertEqual(ssh.detail, "o/heedly · Fix checks · deploy@10.0.0.5:22 · asked in a turn nobody started")
        XCTAssertEqual(ssh.expiresAt, Date(timeIntervalSince1970: 1791400000))
        XCTAssertNotNil(ssh.at)
        XCTAssertEqual(list[1].detail, "as nadin in HQ")
        XCTAssertFalse(list[2].isApproval); XCTAssertEqual(list[2].label, "Question"); XCTAssertEqual(list[2].sessionID, "s3")
        XCTAssertNotNil(list[2].at)
    }
}
