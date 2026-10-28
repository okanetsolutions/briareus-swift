// Regression coverage for the recent server contracts, independent of either app's drawing.
import XCTest
@testable import BriareusMacCore

final class ClientUpdatesTests: XCTestCase {
    private var assessment: JSON {
        ["externalFeedback": true, "standalone": true, "mine": false, "prNumber": 42,
         "findings": [["key": "a", "title": "Check authorization", "recommendation": "fix",
                       "sourceBody": "A developer's original feedback", "reviewAuthorLogin": "reviewer",
                       "assessment": ["verified": true, "worthFixing": true, "evidence": "Checked the route", "reason": "Prevents a regression"]],
                      ["key": "b", "title": "A second claim", "recommendation": "dismissed"]]]
    }
    func testExternalFeedbackAllowsManualVerdictsRegardlessOfPRAuthor() {
        XCTAssertTrue(triageTakesVerdicts(assessment))
        XCTAssertTrue(heldRoundIsMine(assessment))
        let completed = PhoneFindings.completion(assessment, picked: ["a": "fix", "b": "dismissed"], reasons: ["a": "Confirmed"], note: "Only the selected fix")
        XCTAssertEqual(completed["verdicts"][0], ["key": "a", "decision": "fix", "reason": "Confirmed"])
        XCTAssertEqual(completed["verdicts"][1]["decision"], "dismissed")
        XCTAssertEqual(completed["note"], "Only the selected fix")
        // Ordinary reviews of another author's PR keep their existing read/reply flow.
        var ordinary = assessment; ordinary["externalFeedback"] = false
        XCTAssertFalse(triageTakesVerdicts(ordinary)); XCTAssertFalse(heldRoundIsMine(ordinary))
        XCTAssertEqual(PhoneFindings.completion(ordinary, picked: ["a": "fix"], reasons: [:], note: ""), [:])
    }
    func testRecommendationsAreNeverAutomaticallyAppliedAsVerdicts() {
        let completed = triageCompletion(assessment, picked: [:], note: "")
        XCTAssertEqual(completed["verdicts"].items.map { $0["decision"] }, ["optional", "optional"])
        XCTAssertTrue(triageDecision(assessment, assessment["findings"][0], picked: [:]).isEmpty)
        var saved = assessment
        saved["drafts"] = ["verdicts": ["a": ["decision": "dismissed"]]]
        XCTAssertEqual(triageDecision(saved, saved["findings"][0], picked: [:]), "dismissed")
    }
    func testAssessmentRetainsOriginalFeedbackAndIndependentEvidence() throws {
        let details = try XCTUnwrap(FeedbackAssessmentDetails(assessment["findings"][0]))
        XCTAssertEqual(details.source, "A developer's original feedback")
        XCTAssertEqual(details.author, "reviewer")
        XCTAssertTrue(details.verified); XCTAssertTrue(details.worthFixing)
        XCTAssertEqual(details.evidence, "Checked the route")
        XCTAssertEqual(details.reason, "Prevents a regression")
        var unverified = assessment["findings"][0]
        unverified["assessment"]["verified"] = false
        XCTAssertFalse(try XCTUnwrap(FeedbackAssessmentDetails(unverified)).verified)
        XCTAssertNil(FeedbackAssessmentDetails(["title": "Legacy finding"]))
    }
    private func session(_ id: String, created: String, pinned: String? = nil, status: String = "idle") -> Session {
        Session(["id": .string(id), "repo": "o/r", "status": .string(status), "createdAt": .string(created), "pinnedAt": .string(orNull: pinned)])!
    }
    func testPinnedSessionsLeadActiveSessionsAndNewestPinsLeadOlderPins() {
        let older = session("older", created: "2026-01-01T00:00:00Z", pinned: "2026-10-27T00:00:00Z")
        let newer = session("newer", created: "2026-01-02T00:00:00Z", pinned: "2026-10-28T00:00:00Z")
        let active = session("active", created: "2026-10-28T00:00:00Z", status: "running")
        let all = AllSessions(sessions: [active, older, newer], projects: [])
        XCTAssertEqual(all.shown.map(\.id), ["newer", "older", "active"])
        XCTAssertEqual(newer.pinBody, ["pinned": false])
        XCTAssertEqual(active.pinBody, ["pinned": true])
        XCTAssertEqual(Session.parseList(Session.json([newer]))?.first?.pinnedAt, newer.pinnedAt)
    }
    func testLivePinAndUnpinReorderProjectListsAndDoNotLoseRecords() throws {
        let old = session("old", created: "2026-01-01T00:00:00Z")
        let new = session("new", created: "2026-02-01T00:00:00Z")
        var pin = old; pin.raw["pinnedAt"] = "2026-10-28T00:00:00Z"
        let pinned = try XCTUnwrap([new, old].upserting(pin))
        XCTAssertEqual(pinned.map(\.id), ["old", "new"])
        let fresh = session("fresh", created: "2026-10-28T00:00:00Z")
        XCTAssertEqual(pinned.upserting(fresh)?.map(\.id), ["old", "fresh", "new"])
        XCTAssertEqual(pinned.upserting(old)?.map(\.id), ["new", "old"])
        XCTAssertNil(pinned.upserting(pin))
    }
    func testPinRequiresAnAdvertisedBodyFieldAndRetainsCapabilityInCache() throws {
        let pin = try XCTUnwrap(APIRoute.named("pin"))
        let old = [Route(method: "PATCH", path: "/sessions/{id}", access: "manage")]
        XCTAssertFalse(Route.supportsBodyField(old, route: pin))
        let document: JSON = ["paths": ["/sessions/{id}": ["patch": ["x-briareus-access": "manage", "requestBody": ["content": ["application/json": ["schema": ["properties": ["pinned": ["type": "boolean"]]]]]]]]]]
        let routes = try XCTUnwrap(Route.parse(document))
        XCTAssertTrue(Route.supportsBodyField(routes, route: pin))
        XCTAssertTrue(Route.supportsBodyField(try XCTUnwrap(Route.parse(Route.json(routes))), route: pin))
        XCTAssertFalse(Route.allow(routes, method: pin.method, path: pin.path, permission: "read"))
        let resolved = try APIClient.resolve(pin, ["sessionId": "abc", "pinned": true])
        XCTAssertEqual(resolved.path, "sessions/abc"); XCTAssertEqual(resolved.rest, ["pinned": true])
    }
    func testPrintingIsOffByDefaultPreservedAndAbsentOnOlderServers() throws {
        var form = ProjectFormState(row: ["id": 1, "repo": "o/r", "printToolsEnabled": false])
        XCTAssertTrue(form.offered(.printing)); XCTAssertFalse(form.bool(.printing))
        form.bools[.printing] = true
        let body = try form.body().get()
        XCTAssertEqual(body["printToolsEnabled"], true)
        XCTAssertFalse(ProjectFormState(row: ["repo": "o/r"]).offered(.printing))
    }
    func testSSHMonitoringRetainsUnknownRatesAndStaleState() throws {
        let server = try XCTUnwrap(SSHResourceServer(["id": 1700000000000, "label": "Remote", "repo": "o/r", "enabled": true, "monitoringEnabled": true, "stale": true, "latest": ["at": 60000, "metrics": nil]]))
        XCTAssertEqual(server.id, 1700000000000)
        XCTAssertTrue(server.stale); XCTAssertTrue(server.tiles.isEmpty)
        XCTAssertEqual(server.monitoringEdit, ["monitoringEnabled": false])
        XCTAssertEqual(server.measuredAt?.timeIntervalSince1970, 60)
        let tiles = SSHResourceHistory.tiles(["cpu": ["cores": 2, "usagePercent": nil], "memory": ["totalBytes": 1000, "usedBytes": 500, "usedPercent": 50], "network": [["name": "eth0", "rxBytesPerSecond": nil, "txBytesPerSecond": nil]]])
        XCTAssertNil(tiles.first { $0.id == "cpu" }?.fraction)
        XCTAssertEqual(tiles.first { $0.id == "memory" }?.fraction, 0.5)
    }
    func testHistorySplitsLinesAcrossMissingSamplesNullRatesAndOutages() throws {
        let history = try XCTUnwrap(SSHResourceHistory(["serverId": 1, "intervalSeconds": 60, "samples": [
            ["at": 60000, "metrics": ["cpu": ["usagePercent": 10]]],
            ["at": 120000, "metrics": ["cpu": ["usagePercent": 20]]],
            ["at": 180000, "metrics": nil],
            ["at": 240000, "metrics": ["cpu": ["usagePercent": 0]]],
            ["at": 420000, "metrics": ["cpu": ["usagePercent": 30]]],
        ]]))
        let points = history.charts[0].series[0].points
        XCTAssertEqual(points.map(\.value), [10, 20, 0, 30])
        XCTAssertEqual(points.map(\.segment), [0, 0, 1, 2])
        XCTAssertTrue(history.charts[1].series[0].points.isEmpty)
    }
    func testMonitorCredentialRequiresHTTPSAndBothParts() throws {
        let input: JSON = ["serverId": 123, "endpoint": "https://server.test/api/v1/telemetry/ssh/123/samples", "token": "one-time-secret", "intervalSeconds": 60, "retentionHours": 24]
        let serialized = try MonitorCredential(input).configuration
        XCTAssertEqual(JSON.parse(serialized), input)
        XCTAssertThrowsError(try MonitorCredential(["endpoint": "http://server.test", "token": "x"]))
        XCTAssertThrowsError(try MonitorCredential(["endpoint": "https://server.test"]))
    }
    func testPersonalConnectionsUseOnlyTheCallersOwnEndpoints() throws {
        XCTAssertEqual(try PersonalConnectionKind.github.body(token: " personal-token \n", url: "ignored"), ["token": "personal-token"])
        XCTAssertEqual(try PersonalConnectionKind.homeAssistant.body(token: "ha-token", url: " http://homeassistant.local:8123 "), ["token": "ha-token", "url": "http://homeassistant.local:8123"])
        XCTAssertThrowsError(try PersonalConnectionKind.github.body(token: " \n", url: ""))
        XCTAssertThrowsError(try PersonalConnectionKind.homeAssistant.body(token: "x", url: "file:///etc/passwd"))
        XCTAssertThrowsError(try PersonalConnectionKind.homeAssistant.body(token: "x", url: "https://user:secret@host.test"))
        XCTAssertEqual(APIRoute.named(PersonalConnectionKind.github.connect)?.path, "me/github")
        XCTAssertEqual(APIRoute.named(PersonalConnectionKind.homeAssistant.disconnect)?.method, "DELETE")
        XCTAssertTrue(try XCTUnwrap(PersonalConnectionStatus(["connected": true, "login": "alice"])).connected)
        XCTAssertNil(PersonalConnectionStatus(["error": "unavailable"]))
    }
    func testSharingSendsOnlyOneResourcesCompleteMembershipAndPreservesLargeIDs() throws {
        let shares: JSON = [["kind": "project", "id": "3", "userId": 2], ["kind": "sshServer", "id": "3", "userId": 4], ["kind": "project", "id": "5", "userId": 7]]
        XCTAssertEqual(ShareKind.project.members(shares, resourceID: "3"), [2])
        XCTAssertEqual(ShareKind.project.body(resourceID: "3", users: [8, 2]), ["kind": "project", "id": "3", "userIds": [2, 8]])
        XCTAssertEqual(ShareKind.project.body(resourceID: "3", users: []), ["kind": "project", "id": "3", "userIds": []])
        XCTAssertEqual(ShareResource(["id": 1700000000000, "label": "Remote"])?.id, "1700000000000")
        let user = try XCTUnwrap(SharingUser(["id": 2, "name": "Member", "role": "member", "disabled": true]))
        XCTAssertTrue(user.disabled); XCTAssertFalse(user.admin)
    }
    func testPersonalConnectionRefreshPreservesEditsAndReconciliationClearsSecrets() throws {
        var form = PersonalConnectionFormState()
        form.url = "http://edited.local"
        XCTAssertTrue(form.dirty)
        let stored = try XCTUnwrap(PersonalConnectionStatus(["connected": true, "url": "http://saved.local"]))
        form.adopt(stored, preservingEdits: true)
        XCTAssertEqual(form.url, "http://edited.local")
        form.token = "new-token"
        XCTAssertTrue(form.canSave)
        form.adopt(stored, preservingEdits: false)
        XCTAssertTrue(form.token.isEmpty)
        XCTAssertEqual(form.url, "http://saved.local")
        XCTAssertFalse(form.dirty); XCTAssertFalse(form.canSave)
    }
    func testSharingDraftCanBeDiscardedBeforeSelectingAnotherResource() {
        var form = SharingFormState()
        form.select([1, 3]); form.toggle(3); form.toggle(2)
        XCTAssertEqual(form.picked, [1, 2]); XCTAssertTrue(form.dirty)
        form.discard()
        XCTAssertEqual(form.picked, [1, 3]); XCTAssertFalse(form.dirty)
        form.select([8])
        XCTAssertEqual(form.picked, [8]); XCTAssertFalse(form.dirty)
    }

    func testSSHConnectionSaveDoesNotOverwriteSeparatelyEditedMonitoring() throws {
        let form = SSHServerFormState(row: ["id": 123, "repo": "o/r", "host": "host.test", "port": 22, "username": "deploy", "monitoringEnabled": false])
        let body = try form.body().get()
        XCTAssertNil(body.object?["monitoringEnabled"])
        XCTAssertEqual(body["host"], "host.test")
    }

}
