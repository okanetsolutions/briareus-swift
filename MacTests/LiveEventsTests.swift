// What the apps make of the live event streams: the sessions stream's records and deletions, a conversation's record and
// lines, the lists they change, and when a dropped stream is opened again or left to polling.
import XCTest
@testable import BriareusMacCore

final class LiveEventsTests: XCTestCase {
    private func session(_ id: String, _ status: String = "idle", repo: String = "okanet/app") -> Session {
        Session(["id": .string(id), "status": .string(status), "repo": .string(repo)])!
    }

    // MARK: Every session

    func testSessionsEventReadsRecordsAndDeletions() {
        XCTAssertEqual(SessionsEvent("session", session("s1").raw), .session(session("s1")))
        XCTAssertEqual(SessionsEvent("session.deleted", ["id": "s1"]), .deleted("s1"))
        // Without a project to file it under, or an id, there is nothing to do; transcript lines are not asked for.
        XCTAssertNil(SessionsEvent("session", ["id": "s1", "status": "idle"]))
        XCTAssertNil(SessionsEvent("session.deleted", ["id": ""]))
        XCTAssertNil(SessionsEvent("transcript", ["sessionId": "s1", "event": ["seq": 1]]))
    }

    func testUpsertReplacesInPlaceAddsFirstAndSkipsTheSame() {
        let list = [session("s1"), session("s2")]
        XCTAssertNil(list.upserting(session("s2")))
        XCTAssertEqual(list.upserting(session("s2", "running"))?.map(\.status), ["idle", "running"])
        XCTAssertEqual(list.upserting(session("s3"))?.map(\.id), ["s3", "s1", "s2"])
    }

    func testRemoveDropsOnlyWhatIsThere() {
        let list = [session("s1"), session("s2")]
        XCTAssertEqual(list.removing("s1")?.map(\.id), ["s2"])
        XCTAssertNil(list.removing("s9"))
    }

    func testLiveUpsertWaitsForAFullCachedList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = DiskCache(directory: directory, protection: [])
        defer { cache.flush(); try? FileManager.default.removeItem(at: directory) }
        let repo = "okanet/app", key = "sessions:\(repo)"
        func loaded() -> Bool { cache.value(key).flatMap(Session.parseList) != nil }
        let saved = SavedSessionLists(cache: cache)

        XCTAssertNil(saved.upsert(session("s1"), repo: repo))
        XCTAssertNil(cache.value(key))
        XCTAssertFalse(loaded())
        cache.store(["error": "unavailable"], key)
        XCTAssertNil(saved.upsert(session("s1"), repo: repo))
        XCTAssertFalse(loaded())

        // A successful empty read is complete, and live records can extend it.
        cache.store(Session.json([]), key)
        XCTAssertEqual(saved.upsert(session("s1"), repo: repo), [session("s1")])
        XCTAssertTrue(loaded())
        XCTAssertEqual(saved.upsert(session("s2"), repo: repo)?.map(\.id), ["s2", "s1"])
        XCTAssertEqual(saved.upsert(session("s1", "running"), repo: repo)?.map(\.status), ["idle", "running"])
        XCTAssertNil(saved.upsert(session("s1", "running"), repo: repo))
        // Live records change the list held, not the file, until they are saved together.
        XCTAssertEqual(cache.value(key).flatMap(Session.parseList), [])
        XCTAssertEqual(saved.list(repo)?.map(\.id), ["s2", "s1"])
        saved.saveChanges()
        cache.flush()
        let reopened = DiskCache(directory: directory, protection: [])
        XCTAssertEqual(try XCTUnwrap(reopened.value(key).flatMap(Session.parseList)).map(\.id), ["s2", "s1"])
        XCTAssertTrue(loaded())
    }

    func testLiveRemovalOnlyChangesAnExistingFullList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = DiskCache(directory: directory, protection: [])
        defer { cache.flush(); try? FileManager.default.removeItem(at: directory) }
        let repo = "okanet/app", key = "sessions:\(repo)"
        let saved = SavedSessionLists(cache: cache)

        XCTAssertNil(saved.remove("s1", repo: repo))
        XCTAssertNil(cache.value(key))
        let malformed: JSON = ["error": "unavailable"]
        cache.store(malformed, key)
        XCTAssertNil(saved.remove("s1", repo: repo))
        XCTAssertEqual(cache.value(key), malformed)

        cache.store(Session.json([session("s1"), session("s2")]), key)
        XCTAssertNil(saved.remove("unknown", repo: repo))
        XCTAssertEqual(cache.value(key).flatMap(Session.parseList), [session("s1"), session("s2")])
        XCTAssertEqual(saved.remove("s1", repo: repo), [session("s2")])
        cache.flush()
        let reopened = DiskCache(directory: directory, protection: [])
        XCTAssertEqual(reopened.value(key).flatMap(Session.parseList), [session("s2")])
        XCTAssertEqual(saved.remove("s2", repo: repo), [])
        XCTAssertNil(saved.remove("s2", repo: repo))
        XCTAssertEqual(cache.value(key).flatMap(Session.parseList), [])
    }

    func testSavedListsAreReadOnceAndGoWithTheCache() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = DiskCache(directory: directory, protection: [])
        defer { cache.flush(); try? FileManager.default.removeItem(at: directory) }
        let repo = "okanet/app"
        let saved = SavedSessionLists(cache: cache)
        cache.store(Session.json([session("s1")]), "sessions:\(repo)")
        XCTAssertEqual(saved.list(repo), [session("s1")])
        // Saves go to the cache as well as the kept copy.
        saved.save([session("s2"), session("s1")], repo: repo)
        XCTAssertEqual(cache.value("sessions:\(repo)").flatMap(Session.parseList)?.map(\.id), ["s2", "s1"])
        XCTAssertEqual(saved.upsert(session("s3"), repo: repo)?.map(\.id), ["s3", "s2", "s1"])
        // A cache emptied under it (a new device or repository list) leaves no list behind to be saved again.
        cache.removeAll()
        saved.saveChanges()
        XCTAssertNil(cache.value("sessions:\(repo)"))
        XCTAssertNil(saved.list(repo))
        XCTAssertNil(saved.upsert(session("s4"), repo: repo))
        XCTAssertNil(cache.value("sessions:\(repo)"))
        saved.save([session("s1")], repo: repo)
        saved.reset()
        XCTAssertEqual(saved.list(repo), [session("s1")])
        // So does a list removed on its own; the cache's other keys say nothing about it.
        XCTAssertTrue(cache.contains("sessions:\(repo)"))
        cache.remove("sessions:\(repo)")
        XCTAssertFalse(cache.contains("sessions:\(repo)"))
        XCTAssertNil(saved.remove("s1", repo: repo))
        XCTAssertNil(cache.value("sessions:\(repo)"))
        cache.store(Session.json([session("s1")]), "sessions:\(repo)")
        cache.flush()
        XCTAssertTrue(DiskCache(directory: directory, protection: []).contains("sessions:\(repo)"))
    }

    // MARK: One conversation

    func testConversationEventReadsTheRecordEitherWay() {
        XCTAssertEqual(ConversationEvent("session", session("s1").raw), .record(session("s1")))
        XCTAssertEqual(ConversationEvent("session", ["session": session("s1").raw]), .record(session("s1")))
        XCTAssertNil(ConversationEvent("session", ["id": "s1"]))
    }

    func testConversationEventReadsUnnamedNumberedLines() {
        let line: JSON = ["seq": 4, "kind": "assistant", "text": "Done"]
        XCTAssertEqual(ConversationEvent("message", line), .line(line))
        XCTAssertEqual(ConversationEvent("", line), .line(line))
        XCTAssertNil(ConversationEvent("message", ["kind": "assistant"]))
        XCTAssertNil(ConversationEvent("closed", line))
    }

    // MARK: Reconnecting

    func testRetryBacksOffAndStartsAgainOnceOpened() {
        var retry = StreamRetry()
        let dropped = APIError(.network, message: "The connection was lost.")
        XCTAssertEqual(retry.next(after: dropped), 2)
        XCTAssertEqual(retry.next(after: dropped), 4)
        XCTAssertEqual(retry.next(after: dropped), 8)
        retry.opened()
        XCTAssertEqual(retry.next(after: dropped), 2)
        // A stream the server ended comes back in a second.
        retry.opened()
        XCTAssertEqual(retry.next(after: nil), 1)
    }

    func testRetryWaitsForRetryAfter() {
        var retry = StreamRetry()
        XCTAssertEqual(retry.next(after: APIError(.http, status: 503, retryAfter: 30)), 30)
        XCTAssertEqual(retry.next(after: APIError(.http, status: 429, retryAfter: 1)), 4)
    }

    func testRetryGivesUpAfterTheLimitUntilReset() {
        var retry = StreamRetry(limit: 3)
        let dropped = APIError(.network)
        XCTAssertNotNil(retry.next(after: dropped))
        XCTAssertNotNil(retry.next(after: dropped))
        XCTAssertNil(retry.next(after: dropped))
        XCTAssertTrue(retry.stopped)
        XCTAssertNil(retry.next(after: nil))
        retry.reset()
        XCTAssertFalse(retry.stopped)
        XCTAssertEqual(retry.next(after: dropped), 2)
    }

    func testRetryStopsOnARefusalAndNotOnCancelling() {
        for status in [401, 403, 404] {
            var retry = StreamRetry()
            XCTAssertNil(retry.next(after: APIError(.http, status: status)))
            XCTAssertTrue(retry.stopped)
        }
        var retry = StreamRetry()
        XCTAssertNil(retry.next(after: APIError(.cancelled)))
        XCTAssertFalse(retry.stopped)
        XCTAssertEqual(retry.next(after: APIError(.http, status: 500)), 2)
    }
}
