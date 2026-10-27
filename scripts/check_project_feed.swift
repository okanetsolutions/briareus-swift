// Runs the phone's real feed against controlled reads to check cache reuse, tab cancellation and loading indicators.
import Combine
import Foundation

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    @Published var client: APIClient?
    let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    var read: (JSON) async throws -> JSON = { _ in [:] }
    func supports(_ operation: String) -> Bool { true }
    func call(_ operation: String, _ arguments: JSON = [:]) async throws -> JSON { try await read(arguments) }
    private var feeds: [String: ProjectFeed] = [:]
    func feed(_ repo: String) -> ProjectFeed {
        if let feed = feeds[repo] { return feed }
        let feed = ProjectFeed(repo: repo)
        feeds[repo] = feed
        return feed
    }
}

@MainActor
final class SessionFeed {
    static let shared = SessionFeed()
    var live = false
}

func errorText(_ error: Error) -> String { error.localizedDescription }
extension Error {
    var isCancellation: Bool { (self as? APIError)?.kind == .cancelled || self is CancellationError }
}

private struct ClockTransport: HTTPTransport {
    func send(method: String, url: URL, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/json", retryAfter: nil, body: Data("{}".utf8),
                     date: "Tue, 27 Oct 2026 12:00:00 GMT")
    }
}

@MainActor
private final class Reads {
    var pending: [CheckedContinuation<JSON, Error>] = []
    func read() async throws -> JSON {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func waitFor(_ count: Int) async {
        while pending.count < count { await Task.yield() }
    }
}

@main
struct ProjectFeedChecks {
    static let board: JSON = ["syncedAt": "2026-10-27T12:00:00Z", "pulls": [], "issues": []]

    @MainActor
    static func main() async throws {
        let store = Store.shared
        defer { store.cache.removeAll() }
        store.client = try APIClient(address: ServerAddress("https://example.com")!, token: "brm_" + String(repeating: "a", count: 43),
                                     transport: ClockTransport())
        _ = try await store.client!.call("pulls", ["repo": "o/r"])
        try await automaticRead(staleServer: false)
        try await automaticRead(staleServer: true)
        try await cancelledTabRead(join: false)
        try await cancelledTabRead(join: true)
        try await overlappingReads(failFirst: false)
        try await overlappingReads(failFirst: true)
        liveSessionsAfterCacheWipe()
        liveSessionsBeforeFirstRead()
        liveSessionDeletions()
        try await coalescedSessionUpdates()
        print("Project feed cache reuse, cancellation, overlapping reads, live sessions and coalesced overview checks passed")
    }

    @MainActor
    static func coalescedSessionUpdates() async throws {
        let store = Store.shared, model = ProjectsModel.shared, repo = "burst/sessions"
        store.cache.removeAll()
        var requests = 0
        store.read = { _ in
            requests += 1
            return requests == 1 ? ["projects": [["repo": .string(repo)]]] : ["sessions": []]
        }
        try await model.load()
        let feed = store.feed(repo)
        var changes = 0
        let subscription = model.$allSessions.dropFirst().sink { _ in changes += 1 }
        defer { subscription.cancel() }
        for n in 1...100 {
            feed.upsert(Session(["id": .string("s\(n)"), "repo": .string(repo), "status": "running"])!)
        }
        precondition(changes == 0, "A stream burst must not rebuild every project's overview for each record")
        for _ in 0..<100 {
            if changes > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(changes == 1 && model.allSessions.sessions.count == 100 && model.overview.working.count == 100,
                     "One overview refresh must include the entire burst")
        feed.remove("s1")
        model.recount()
        precondition(changes == 2 && model.allSessions.sessions.count == 99,
                     "An explicit recount must reflect deletions immediately")
        try await Task.sleep(for: .milliseconds(150))
        precondition(changes == 2, "An explicit recount must cancel the pending refresh")
        feed.upsert(Session(["id": "s101", "repo": .string(repo), "status": "running"])!)
        store.cache.removeAll()
        store.client = nil
        try await Task.sleep(for: .milliseconds(150))
        precondition(model.projects.isEmpty && model.allSessions.sessions.isEmpty && !model.sessionsLoaded,
                     "A pending overview refresh must not restore data after sign-out")
    }

    @MainActor
    static func liveSessionsAfterCacheWipe() {
        let store = Store.shared, repo = "live/wiped"
        let feed = ProjectFeed(repo: repo)
        let first = Session(["id": "s1", "repo": .string(repo), "status": "idle"])!
        let second = Session(["id": "s2", "repo": .string(repo), "status": "idle"])!
        let running = Session(["id": "s1", "repo": .string(repo), "status": "running"])!
        feed.adopt([first, second])
        store.cache.removeAll()
        feed.upsert(running)
        precondition(feed.sessions == [running, second] && feed.sessionsLoaded,
                     "A cache wipe must not prevent updates to the list still on screen")
        let added = Session(["id": "s3", "repo": .string(repo), "status": "idle"])!
        feed.upsert(added)
        precondition(feed.sessions == [added, running, second], "Live additions must preserve the other rows")
        precondition(store.cache.value("sessions:\(repo)") == nil,
                     "Live events must not restore a wiped full-list cache")
        feed.adopt([added, running, second])
        feed.upsert(first)
        precondition(store.cache.value("sessions:\(repo)").flatMap(Session.parseList) == [added, first, second],
                     "Live events must keep updating the cache after a full read")
    }

    @MainActor
    static func liveSessionsBeforeFirstRead() {
        let repo = "live/unread", feed = ProjectFeed(repo: repo)
        let session = Session(["id": "s1", "repo": .string(repo), "status": "running"])!
        feed.upsert(session)
        feed.upsert(session)
        precondition(feed.sessions == [session], "An unread list must show live records without duplicates")
        precondition(!feed.sessionsLoaded && Store.shared.cache.value("sessions:\(repo)") == nil,
                     "A live record alone must not mark the full list as read")
    }

    @MainActor
    static func liveSessionDeletions() {
        let store = Store.shared
        for drop in [false, true] {
            for state in ["unread", "wiped", "saved"] {
                let repo = "delete/\(drop)/\(state)", key = "sessions:\(repo)"
                let feed = ProjectFeed(repo: repo)
                let first = Session(["id": "s1", "repo": .string(repo), "status": "idle"])!
                let second = Session(["id": "s2", "repo": .string(repo), "status": "idle"])!
                if state != "unread" { feed.adopt([first, second]) }
                if state == "wiped" { store.cache.remove(key) }
                feed.upsert(first)
                feed.upsert(second)
                store.cache.store(["events": []], "transcript:s1")
                if drop { feed.drop("s1") } else { feed.remove("s1") }
                precondition(feed.sessions == [second], "Deletion must preserve the other live rows")
                precondition(feed.sessionsLoaded == (state != "unread"),
                             "Deletion must not mark a never-read list loaded")
                precondition(store.cache.value("transcript:s1") == nil, "Deletion must clear the saved transcript")
                let saved = store.cache.value(key).flatMap(Session.parseList)
                precondition(saved == (state == "saved" ? [second] : nil),
                             "Deletion may update only an existing full-list cache")
                let all = AllSessions(sessions: feed.sessions, projects: [Project(repo: repo)])
                precondition(all.cacheIsLoaded(projectsLoaded: true, cachedRepos: saved == nil ? [] : [repo]) == (state == "saved"),
                             "Live-only deletions must not make All complete")
                if drop { feed.drop("s2") } else { feed.remove("s2") }
                precondition(feed.sessions.isEmpty)
                precondition(store.cache.value(key).flatMap(Session.parseList) == (state == "saved" ? [] : nil),
                             "Deleting the final row must preserve cache completeness")
                if drop { feed.drop("unknown") } else { feed.remove("unknown") }
                precondition(store.cache.value(key).flatMap(Session.parseList) == (state == "saved" ? [] : nil),
                             "An unknown deletion must not create a cache")
            }
        }
    }

    @MainActor
    static func automaticRead(staleServer: Bool) async throws {
        let repo = "cache/\(staleServer)", reads = Reads()
        let stale: JSON = ["syncedAt": "2026-10-27T11:50:00Z", "pulls": [], "issues": []]
        Store.shared.cache.store(stale, "pulls:\(repo)")
        let feed = ProjectFeed(repo: repo)
        var requests: [Bool] = []
        Store.shared.read = { arguments in
            requests.append(arguments["fresh"].string == "1")
            return try await reads.read()
        }
        let opening = Task { try await feed.refreshBoardIfStale() }
        await reads.waitFor(1)
        precondition(requests == [false], "A stale local copy must try the server cache first")
        precondition(feed.boardReading && feed.board == stale)
        reads.pending[0].resume(returning: staleServer ? stale : board)
        if staleServer {
            await reads.waitFor(2)
            precondition(requests == [false, true], "Only a stale server answer should force GitHub")
            precondition(feed.boardReading, "Spinner must remain visible through the second request")
            reads.pending[1].resume(returning: board)
        }
        let answered = try await opening.value
        precondition(answered && feed.board == board && !feed.boardReading)
        precondition(requests == (staleServer ? [false, true] : [false]))
    }

    @MainActor
    static func cancelledTabRead(join: Bool) async throws {
        let reads = Reads(), feed = ProjectFeed(repo: "cancel/\(join)")
        Store.shared.read = { _ in try await reads.read() }
        let active = join ? Task { try await feed.loadBoard(fresh: true) } : nil
        if join { await reads.waitFor(1) }
        var entered = false
        let opening = Task { entered = true; return try await feed.refreshBoardIfStale() }
        while !entered { await Task.yield() }
        await reads.waitFor(1)
        opening.cancel()
        reads.pending[0].resume(returning: board)
        let answered = try await opening.value
        try await active?.value
        precondition(answered, "A completed read must settle the error/filter even after tab cancellation")
        precondition(feed.boardLoaded && !feed.boardReading && feed.board == board)
        let skipped = try await feed.refreshBoardIfStale()
        precondition(!skipped && reads.pending.count == 1, "A fresh cached list must preserve the error/filter")
    }

    @MainActor
    static func overlappingReads(failFirst: Bool) async throws {
        let reads = Reads(), feed = ProjectFeed(repo: "overlap/\(failFirst)")
        Store.shared.read = { _ in try await reads.read() }
        let active = Task { try await feed.loadBoard(fresh: true) }
        await reads.waitFor(1)
        var entered = 0, finished = 0
        let queued = (0..<2).map { _ in Task {
            entered += 1
            defer { finished += 1 }
            try await feed.loadBoard(fresh: true)
        } }
        while entered < 2 { await Task.yield() }
        reads.pending[0].resume(returning: board)
        try await active.value
        await reads.waitFor(3)
        precondition(feed.boardReading)
        if failFirst { reads.pending[1].resume(throwing: APIError(.network)) }
        else { reads.pending[1].resume(returning: board) }
        while finished < 1 { await Task.yield() }
        precondition(feed.boardReading, "Spinner must stay visible while the other fresh request is pending")
        reads.pending[2].resume(returning: board)
        var failures = 0
        for task in queued {
            do { try await task.value } catch { failures += 1 }
        }
        precondition(failures == (failFirst ? 1 : 0))
        precondition(!feed.boardReading, "Spinner must stop after every read completes, including failures")
    }
}
