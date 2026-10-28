// Regression coverage for the recent server contracts, independent of either app's drawing.
import XCTest
@testable import BriareusMacCore

final class ClientUpdatesTests: XCTestCase {
    func testSharedWritePolicyBlocksDuplicatesUncertainOutcomesAndUnsupportedRoutes() {
        for supported in [false, true] {
            for busy in [false, true] {
                for uncertain in [false, true] {
                    XCTAssertEqual(SettingsWritePolicy.allows(supported: supported, busy: busy, uncertain: uncertain), supported && !busy && !uncertain)
                }
            }
        }
        XCTAssertFalse(SettingsWritePolicy.isUncertain(APIError(.http, status: 403)))
        for error in [APIError(.http, status: 502), APIError(.network), APIError(.cancelled), APIError(.nonJSON)] {
            XCTAssertTrue(SettingsWritePolicy.isUncertain(error))
        }
        XCTAssertTrue(SettingsWritePolicy.isUncertain(CancellationError()))
    }
    func testPersonalConnectionRecoveryKeepsAddressAndClearsSecret() throws {
        var form = PersonalConnectionFormState()
        let saved = try XCTUnwrap(PersonalConnectionStatus(["connected": false]))
        form.adopt(saved, preservingEdits: false)
        form.url = "http://typed.local:8123"; form.token = "secret"
        XCTAssertTrue(form.canSave(supported: true, busy: false, uncertain: false))
        XCTAssertFalse(form.canSave(supported: false, busy: false, uncertain: false))
        XCTAssertFalse(form.canSave(supported: true, busy: true, uncertain: false))
        XCTAssertFalse(form.canSave(supported: true, busy: false, uncertain: true))
        form.checkOutcome()
        form.adopt(saved, preservingEdits: true)
        XCTAssertEqual(form.url, "http://typed.local:8123")
        XCTAssertTrue(form.token.isEmpty)
        XCTAssertFalse(form.canSave)
        XCTAssertFalse(form.canDisconnect(supported: true))
        form.adopt(try XCTUnwrap(PersonalConnectionStatus(["connected": true])), preservingEdits: true)
        XCTAssertTrue(form.canDisconnect(supported: true))
        XCTAssertFalse(form.canDisconnect(supported: false))
    }
    func testSharingSaveRequiresAnEditableLoadedResourceAndChanges() {
        var form = SharingFormState()
        XCTAssertFalse(form.canSave(resourceID: "1", available: true, loaded: true, supported: true, busy: false, uncertain: false))
        form.toggle(2)
        XCTAssertTrue(form.canSave(resourceID: "1", available: true, loaded: true, supported: true, busy: false, uncertain: false))
        XCTAssertFalse(form.canSave(resourceID: "", available: true, loaded: true, supported: true, busy: false, uncertain: false))
        XCTAssertFalse(form.canSave(resourceID: "1", available: false, loaded: true, supported: true, busy: false, uncertain: false))
        XCTAssertFalse(form.canSave(resourceID: "1", available: true, loaded: false, supported: true, busy: false, uncertain: false))
        XCTAssertFalse(form.canSave(resourceID: "1", available: true, loaded: true, supported: false, busy: false, uncertain: false))
        XCTAssertFalse(form.canSave(resourceID: "1", available: true, loaded: true, supported: true, busy: true, uncertain: false))
        XCTAssertFalse(form.canSave(resourceID: "1", available: true, loaded: true, supported: true, busy: false, uncertain: true))
    }
    func testMonitoringSerializesReadsAndWritesAndRetainsConfigurationOnToggle() throws {
        XCTAssertTrue(SSHMonitoringPolicy.canLoad(loading: false, busy: false, afterWrite: false))
        XCTAssertFalse(SSHMonitoringPolicy.canLoad(loading: false, busy: true, afterWrite: false))
        XCTAssertTrue(SSHMonitoringPolicy.canLoad(loading: false, busy: true, afterWrite: true))
        XCTAssertFalse(SSHMonitoringPolicy.canLoad(loading: true, busy: true, afterWrite: true))
        XCTAssertTrue(SSHMonitoringPolicy.canWrite(serverID: 1, supported: true, loading: false, busy: false, uncertain: false))
        XCTAssertFalse(SSHMonitoringPolicy.canWrite(serverID: nil, supported: true, loading: false, busy: false, uncertain: false))
        XCTAssertFalse(SSHMonitoringPolicy.canWrite(serverID: 1, supported: true, loading: true, busy: false, uncertain: false))
        XCTAssertFalse(SSHMonitoringPolicy.canWrite(serverID: 1, supported: true, loading: false, busy: true, uncertain: false))
        XCTAssertFalse(SSHMonitoringPolicy.canWrite(serverID: 1, supported: true, loading: false, busy: false, uncertain: true))
        XCTAssertFalse(SSHMonitoringPolicy.canWrite(serverID: 1, supported: false, loading: false, busy: false, uncertain: false))
        XCTAssertFalse(SSHMonitoringAction.toggle.clearsCredential)
        XCTAssertTrue(SSHMonitoringAction.issue.clearsCredential)
        XCTAssertTrue(SSHMonitoringAction.revoke.clearsCredential)
        XCTAssertEqual(try SSHMonitoringAction.toggle.credential(from: [:], current: "configuration"), "configuration")
        XCTAssertNil(try SSHMonitoringAction.revoke.credential(from: [:], current: nil))
        let answer: JSON = ["endpoint": "https://host.test/telemetry", "token": "secret"]
        XCTAssertEqual(JSON.parse(try XCTUnwrap(SSHMonitoringAction.issue.credential(from: answer, current: nil))), answer)
        XCTAssertThrowsError(try SSHMonitoringAction.issue.credential(from: [:], current: nil))
    }
    func testRemoteTilesDistinguishMissingReadingsFromMeasuredZero() {
        let missing = SSHResourceHistory.tiles(["cpu": [:], "memory": [:], "disks": [["mount": "/"]]])
        let zero = SSHResourceHistory.tiles(["cpu": ["cores": 0, "usagePercent": 0], "memory": ["usedBytes": 0, "totalBytes": 0, "swapUsedBytes": 0, "swapTotalBytes": 0], "uptimeSeconds": 0, "disks": [["mount": "/", "usedBytes": 0, "totalBytes": 0]]])
        for id in ["cpu", "memory", "uptime", "swap", "disk:/"] {
            XCTAssertNotEqual(missing.first { $0.id == id }?.value, zero.first { $0.id == id }?.value)
            XCTAssertNil(missing.first { $0.id == id }?.fraction)
        }
        for id in ["cpu", "memory", "swap", "disk:/"] {
            XCTAssertNotEqual(missing.first { $0.id == id }?.detail, zero.first { $0.id == id }?.detail)
        }
        let partial = SSHResourceHistory.tiles(["memory": ["usedBytes": 512]])
        XCTAssertEqual(partial.first { $0.id == "memory" }?.value, StatsFormat.bytes(512))
        XCTAssertEqual(partial.first { $0.id == "memory" }?.detail, missing.first { $0.id == "memory" }?.detail)
    }
    func testIsolatedRemoteReadingsRemainPlottableWithoutJoiningGaps() throws {
        let history = try XCTUnwrap(SSHResourceHistory(["serverId": 1, "samples": [
            ["at": 60000, "metrics": nil],
            ["at": 120000, "metrics": ["cpu": ["usagePercent": 0]]],
            ["at": 180000, "metrics": nil],
        ]]))
        let chart = history.charts[0]
        XCTAssertTrue(chart.plots)
        XCTAssertEqual(chart.series[0].isolatedPoints.map(\.value), [0])
        XCTAssertFalse(history.charts[1].plots)
        var series = chart.series[0]
        series.points += [.init(at: Date(timeIntervalSince1970: 240), value: 10, segment: 2),
                          .init(at: Date(timeIntervalSince1970: 300), value: 20, segment: 2)]
        XCTAssertEqual(series.isolatedPoints.map(\.value), [0])
        XCTAssertEqual(series.points.map(\.segment), [1, 2, 2])
    }
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
    func testLiveUnpinPreservesCreationMillisecondsAndStatusEventsDoNotResort() throws {
        let old = session("old", created: "2026-10-28T00:00:00.100Z")
        let new = session("new", created: "2026-10-28T00:00:00.900Z")
        var pinned = old; pinned.raw["pinnedAt"] = "2026-10-28T01:00:00.000Z"
        XCTAssertEqual([pinned, new].upserting(old)?.map(\.id), ["new", "old"])
        var running = old; running.raw["status"] = "running"
        XCTAssertEqual([old, new].upserting(running)?.map(\.id), ["old", "new"])
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

    func testProjectConversationGroupsPutEveryPinBeforeUnpinnedWorkingSessions() {
        let working = session("working", created: "2026-10-28T00:00:00Z", status: "running")
        let recent = session("recent", created: "2026-10-28T00:00:00Z")
        let oldPin = session("old-pin", created: "2026-01-01T00:00:00Z", pinned: "2026-10-27T00:00:00Z", status: "running")
        let idlePin = session("idle-pin", created: "2026-01-01T00:00:00Z", pinned: "2026-10-28T00:00:00Z")
        let groups = ConversationGroups([working, oldPin, recent, idlePin])
        XCTAssertEqual(groups.pinned.map(\.id), ["idle-pin", "old-pin"])
        XCTAssertEqual(groups.active.map(\.id), ["working"])
        XCTAssertEqual(groups.recent.map(\.id), ["recent"])
        XCTAssertEqual((groups.pinned + groups.active + groups.recent).count, 4)
    }
    func testStaleFeedbackDiscardsTheAssessmentWhileOrdinaryRoundsReviewTheNewHead() {
        XCTAssertEqual(triageStaleResolution(["externalFeedback": true, "stale": true]), .discardAssessment)
        XCTAssertEqual(triageStaleResolution(["standalone": true, "mine": true, "stale": true]), .reviewMovedHead)
    }
    func testSharingSaveReplacesOnlyOneResourceAndRejectsMismatchedEchoes() throws {
        let previous: JSON = [["kind": "project", "id": "5", "userId": 2], ["kind": "sshServer", "id": "5", "userId": 3], ["kind": "project", "id": "6", "userId": 4]]
        let update = try SharingUpdate(["kind": "project", "id": "5", "userIds": [7]], kind: .project, resourceID: "5", previous: previous)
        XCTAssertEqual(update.members, [7])
        XCTAssertEqual(ShareKind.project.members(update.shares, resourceID: "5"), [7])
        XCTAssertEqual(ShareKind.sshServer.members(update.shares, resourceID: "5"), [3])
        XCTAssertEqual(ShareKind.project.members(update.shares, resourceID: "6"), [4])
        let removed = try SharingUpdate(["kind": "project", "id": "5", "userIds": []], kind: .project, resourceID: "5", previous: update.shares)
        XCTAssertTrue(ShareKind.project.members(removed.shares, resourceID: "5").isEmpty)
        XCTAssertEqual(removed.shares.count, 2)
        let invalidResponses: [JSON] = [["kind": "sshServer", "id": "5", "userIds": [1]], ["kind": "project", "id": "6", "userIds": [1]], ["kind": "project", "id": "5", "userIds": [-1]], ["kind": "project", "id": "5", "userIds": ["invalid"]]]
        for bad in invalidResponses {
            XCTAssertThrowsError(try SharingUpdate(bad, kind: .project, resourceID: "5", previous: previous))
        }
        var form = SharingFormState(); form.select([7])
        XCTAssertEqual(form.membership(for: 7), .shared)
        XCTAssertEqual(form.membership(for: 3), .notShared)
    }

}
