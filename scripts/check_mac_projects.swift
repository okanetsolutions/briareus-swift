// Runs the Mac's real project/sidebar models with offline reads to check live bursts and unchanged responses.
import Combine
import Foundation

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    @Published var client: APIClient?
    var active = true
    let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    var read: (String, JSON) async throws -> JSON = { _, _ in .null }
    func supports(_ operation: String) -> Bool { true }
    func call(_ operation: String, _ arguments: JSON = [:]) async throws -> JSON { try await read(operation, arguments) }
}

@MainActor
final class AttentionModel {
    static let shared = AttentionModel()
    func load() async -> APIError? { nil }
}

@MainActor
enum Dialogs {
    static func confirm(_ title: String, _ message: String, continueLabel: String, destructive: Bool) -> Bool { false }
}

func errorText(_ error: Error) -> String { error.localizedDescription }
extension Error {
    var isCancellation: Bool { (self as? APIError)?.kind == .cancelled || self is CancellationError }
}

@main
struct MacProjectsChecks {
    @MainActor
    static func main() async throws {
        let store = Store.shared
        defer { store.cache.removeAll() }
        store.client = try APIClient(address: ServerAddress("https://example.com")!,
                                     token: "brm_" + String(repeating: "a", count: 43))
        let projects: JSON = ["projects": [["repo": "o/a"], ["repo": "o/b"]]]
        store.read = { operation, _ in operation == "projects" ? projects : ["sessions": []] }
        let model = ProjectsModel.shared
        await model.load()
        precondition(model.sessionsLoaded && model.allSessions.sessions.isEmpty)
        try await unchangedReads()
        try await streamBurst()
        try await immediateRecount()
        try await signOut()
        print("Mac project/sidebar unchanged reads, burst aggregation, deletion and sign-out checks passed")
    }

    @MainActor
    static func unchangedReads() async throws {
        let model = ProjectsModel.shared
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        await model.load()
        precondition(changes == 0, "An unchanged projects response must not invalidate the sidebar")
        subscription.cancel()

        let sidebar = SidebarSessions(project: model.projects[0])
        await sidebar.load()
        changes = 0
        let sidebarSubscription = sidebar.objectWillChange.sink { changes += 1 }
        await sidebar.load()
        precondition(changes == 0, "An unchanged session poll must not redraw the list")
        sidebarSubscription.cancel()
        model.recount()
    }

    @MainActor
    static func streamBurst() async throws {
        let store = Store.shared, model = ProjectsModel.shared
        var changes = 0
        let subscription = model.$allSessions.dropFirst().sink { _ in changes += 1 }
        defer { subscription.cancel() }
        for n in 1...100 {
            let repo = n.isMultiple(of: 2) ? "o/a" : "o/b"
            let session = Session(["id": .string("s\(n)"), "repo": .string(repo), "status": "running"])!
            precondition(store.cache.upsertSession(session, repo: repo) != nil)
            model.scheduleRecount()
        }
        precondition(changes == 0, "A catch-up burst must not aggregate every project's sessions for each record")
        for _ in 0..<100 {
            if changes > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(changes == 1 && model.allSessions.sessions.count == 100 && model.overview.workingCount == 100,
                     "One aggregation must include all projects in the burst")
        precondition(model.counts == ["o/a": 50, "o/b": 50] && model.busy == ["o/a": true, "o/b": true])
    }

    @MainActor
    static func immediateRecount() async throws {
        let model = ProjectsModel.shared
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        model.forget(repo: "o/b", id: "s1")
        model.recount()
        precondition(model.allSessions.sessions.count == 99 && model.counts["o/b"] == 49,
                     "An explicit recount must include a pending deletion immediately")
        let before = changes
        try await Task.sleep(for: .milliseconds(150))
        precondition(changes == before, "An explicit recount must cancel the scheduled aggregation")
    }

    @MainActor
    static func signOut() async throws {
        let store = Store.shared, model = ProjectsModel.shared
        model.scheduleRecount()
        store.cache.removeAll()
        store.client = nil
        try await Task.sleep(for: .milliseconds(150))
        precondition(model.projects.isEmpty && model.allSessions.sessions.isEmpty && !model.sessionsLoaded,
                     "A pending aggregation must not restore state after sign-out")
        precondition(model.counts.isEmpty && model.busy.isEmpty && model.overview.quiet)
    }
}
