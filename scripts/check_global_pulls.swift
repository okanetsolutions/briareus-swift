// Runs the Mac's actual board read and global model code with controlled, offline requests.
import Combine
import Foundation

@MainActor
final class Store {
    static let shared = Store()
    var client: APIClient?
    let canManage = true
    let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    var read: (String, JSON) async throws -> JSON = { _, _ in .null }
    func supports(_ operation: String) -> Bool { true }
    func call(_ operation: String, _ arguments: JSON = [:]) async throws -> JSON { try await read(operation, arguments) }
}

@MainActor
func boardCall(_ operation: String, _ arguments: JSON = [:]) async -> Result<JSON, APIError> {
    do { return .success(try await Store.shared.call(operation, arguments)) }
    catch { return .failure(error as? APIError ?? APIError(.cancelled)) }
}

extension Result where Failure == APIError {
    var value: Success? { if case .success(let value) = self { return value }; return nil }
    var error: APIError? { if case .failure(let error) = self { return error }; return nil }
}

@MainActor
enum PullsGate {
    static let cooldown = PullsCooldown()
    static func read(_ repo: String, fresh: Bool, ifStale: Bool) async -> Result<JSON, APIError>? {
        await boardCall("pulls", ["repo": .string(repo), "fresh": .bool(fresh)])
    }
}

@MainActor
final class BoardModel: ObservableObject {
    let repo: String
    @Published var board: JSON = .null
    var catalog: JSON = []
    var runs: [Session] = []
    var uncertain = false, reading = false, loaded = false
    var writeError: String?, error: String?
    var syncedAt: Date?
    var readGen = 0, cooldownTick = 0
    let issueStatus = IssueStatusChecks()
    init(repo: String) { self.repo = repo }
    func show(_ answer: JSON, saved: Bool) { board = answer }
    func loadRuns() async {
        if let answer = await boardCall("sessions", ["repo": .string(repo)]).value {
            runs = Session.parseList(answer) ?? []
        }
    }
}

@MainActor
final class IssueStatusChecks { func next() {} }
@MainActor
enum BoardEdits { static let login: String? = nil }
enum Screen {
    case pull(repo: String, number: Int, stack: JSON?, summary: JSON)
    case issue(repo: String, issue: JSON)
}
@MainActor
final class Navigator {
    static let shared = Navigator()
    func push(_ screen: Screen) {}
}

@MainActor
private final class PendingRead {
    var continuation: CheckedContinuation<JSON, Error>?
    func read() async throws -> JSON { try await withCheckedThrowingContinuation { continuation = $0 } }
    func wait() async { while continuation == nil { await Task.yield() } }
}

@main
struct GlobalPullsChecks {
    static let openBoard: JSON = ["pulls": [["number": 7]], "issues": []]
    static let merged: JSON = ["pulls": [], "issues": []]
    static let projects: JSON = ["projects": [["repo": "o/a"], ["repo": "o/b"]]]

    static func client() throws -> APIClient {
        try APIClient(address: ServerAddress("https://example.com")!, token: "brm_" + String(repeating: "a", count: 43))
    }

    @MainActor
    static func main() async throws {
        let store = Store.shared
        defer { store.cache.removeAll() }
        store.client = try client()
        try await orderedReads(failedPoll: false)
        try await orderedReads(failedPoll: true)
        try await parallelReadsAndCatalogThrottle()
        print("Global pull read ordering, stale failures, parallel sessions/actions and catalog throttle checks passed")
    }

    @MainActor
    static func orderedReads(failedPoll: Bool) async throws {
        let pollRead = PendingRead(), freshRead = PendingRead(), model = BoardModel(repo: "o/a")
        model.show(openBoard, saved: true)
        Store.shared.read = { _, arguments in
            try await (arguments["fresh"].is(true) ? freshRead : pollRead).read()
        }
        let poll = Task { await model.loadBoard() }
        await pollRead.wait()
        let refresh = Task { await model.loadBoard(fresh: true) }
        await freshRead.wait()
        freshRead.continuation?.resume(returning: merged)
        let freshResult = await refresh.value
        precondition(freshResult?.value == merged && !model.reading)
        if failedPoll { pollRead.continuation?.resume(throwing: APIError(.http, status: 503)) }
        else { pollRead.continuation?.resume(returning: openBoard) }
        let pollResult = await poll.value
        precondition(pollResult?.value == merged && model.board == merged && model.error == nil,
                     "An older poll must return the accepted board without restoring rows or errors")
        precondition(Store.shared.cache.value("pulls:o/a") == merged,
                     "An older poll must not overwrite the fresh cache")
    }

    @MainActor
    static func parallelReadsAndCatalogThrottle() async throws {
        let store = Store.shared, actions = PendingRead(), sessions = PendingRead()
        store.cache.store(projects, "projects")
        var calls: [String] = [], holdReads = true
        let catalog: JSON = ["actions": [["id": "review", "label": "Review"]]]
        store.read = { operation, arguments in
            let repo = arguments["repo"].string ?? ""
            calls.append("\(operation):\(repo)")
            switch operation {
            case "projects": return projects
            case "actions": return holdReads ? try await actions.read() : catalog
            case "pulls": return openBoard
            case "sessions": return holdReads && repo == "o/a" ? try await sessions.read() : []
            default: preconditionFailure("Unexpected operation \(operation)")
            }
        }
        let model = GlobalPullsModel()
        let load = Task { await model.load() }
        await actions.wait()
        await sessions.wait()
        while !model.state.loaded { await Task.yield() }
        precondition(calls.contains("pulls:o/b") && model.state.rows.count == 2,
                     "A slow catalog or one project's sessions must not delay the other boards")
        actions.continuation?.resume(returning: catalog)
        sessions.continuation?.resume(returning: [])
        let firstError = await load.value
        precondition(firstError == nil && model.boards.values.allSatisfy { $0.catalog == catalog["actions"] })
        holdReads = false
        let nextError = await model.load()
        precondition(nextError == nil && calls.filter { $0 == "actions:" }.count == 1,
                     "Polling again within five minutes must reuse the catalog")
        store.client = try client()
        let switchedError = await model.load()
        precondition(switchedError == nil && calls.filter { $0 == "actions:" }.count == 2,
                     "A new connection must read its own catalog")
    }
}
