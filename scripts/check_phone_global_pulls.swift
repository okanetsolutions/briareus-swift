// Runs the phone's actual global model and project feeds with controlled, offline requests.
import Combine
import Foundation

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    @Published var client: APIClient?
    let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    var read: (String, JSON) async throws -> JSON = { _, _ in .null }
    private var feeds: [String: ProjectFeed] = [:]
    func supports(_ operation: String) -> Bool { true }
    func call(_ operation: String, _ arguments: JSON = [:]) async throws -> JSON { try await read(operation, arguments) }
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

@MainActor
final class ErrandCatalog {
    static let shared = ErrandCatalog()
    var catalog: JSON = []
    func load() async {
        if let answer = try? await Store.shared.call("actions") { catalog = answer["actions"] }
    }
}

@MainActor
final class BoardPullActionsModel {
    let feed: ProjectFeed
    init(repo: String) { feed = Store.shared.feed(repo) }
    func checked() {}
}

@MainActor
enum GitHubLogin { static let current: String? = nil }

func errorText(_ error: Error) -> String { error.localizedDescription }
extension Error {
    var isCancellation: Bool { (self as? APIError)?.kind == .cancelled || self is CancellationError }
}

@MainActor
private final class PendingRead {
    var continuation: CheckedContinuation<JSON, Error>?
    func read() async throws -> JSON { try await withCheckedThrowingContinuation { continuation = $0 } }
    func wait() async { while continuation == nil { await Task.yield() } }
}

@main
struct PhoneGlobalPullsChecks {
    @MainActor
    static func main() async throws {
        let store = Store.shared
        defer { store.cache.removeAll() }
        store.client = try APIClient(address: ServerAddress("https://example.com")!,
                                     token: "brm_" + String(repeating: "a", count: 43))
        try await parallelReads(fresh: false, failedSessions: false)
        try await parallelReads(fresh: true, failedSessions: true)
        print("Phone global boards progress during slow catalog/session reads; refresh and session failure checks passed")
    }

    @MainActor
    static func parallelReads(fresh: Bool, failedSessions: Bool) async throws {
        let store = Store.shared, actions = PendingRead(), sessions = PendingRead()
        let firstRepo = "o/a-\(fresh)", secondRepo = "o/b-\(fresh)"
        let projects: JSON = ["projects": [["repo": .string(firstRepo)], ["repo": .string(secondRepo)]]]
        let board: JSON = ["syncedAt": .string(ISO8601DateFormatter().string(from: Date())),
                           "pulls": [["number": 7]], "issues": []]
        let catalog: JSON = ["actions": [["id": "review", "label": "Review"]]]
        store.cache.store(projects, "projects")
        var calls: [String] = []
        store.read = { operation, arguments in
            let repo = arguments["repo"].string ?? ""
            calls.append("\(operation):\(repo)")
            switch operation {
            case "projects": return projects
            case "actions": return try await actions.read()
            case "pulls":
                precondition(!fresh || arguments["fresh"].string == "1",
                             "The board read must preserve the caller's refresh request")
                return board
            case "sessions": return repo == firstRepo ? try await sessions.read() : []
            default: preconditionFailure("Unexpected operation \(operation)")
            }
        }
        let model = GlobalPullsModel()
        var finished = false
        let load = Task {
            defer { finished = true }
            return await model.load(fresh: fresh)
        }
        await actions.wait()
        await sessions.wait()
        while !model.state.loaded { await Task.yield() }
        precondition(calls.contains("pulls:\(secondRepo)") && model.state.rows.count == 2,
                     "A slow catalog or one project's sessions must not delay the other boards")
        precondition(!finished && !store.feed(firstRepo).sessionsLoaded,
                     "The load must keep its auxiliary reads structured while boards are already visible")
        actions.continuation?.resume(returning: catalog)
        if failedSessions { sessions.continuation?.resume(throwing: APIError(.http, status: 503)) }
        else { sessions.continuation?.resume(returning: []) }
        let error = await load.value
        precondition(error == nil && finished && model.state.rows.count == 2,
                     "Session failures must not replace successful board results")
        precondition(ErrandCatalog.shared.catalog == catalog["actions"])
        precondition(store.feed(firstRepo).sessionsLoaded == !failedSessions)
        precondition(store.cache.value("pulls:\(secondRepo)") == board)
    }
}
