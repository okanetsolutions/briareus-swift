// Exercise each app's real dashboard model with delayed, failed and cancelled reads; no network.
import Combine
import Foundation

@MainActor
final class Store {
    static let shared = Store()
    let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), protection: [])
    var offered: Set<String> = ["server_stats", "sessions_stats", "ssh_monitoring"]
    var calls: [String] = []
    var respond: (String) async throws -> JSON = { _ in [:] }
    func supports(_ name: String) -> Bool { offered.contains(name) }
    func call(_ name: String, _ args: JSON = [:]) async throws -> JSON {
        calls.append(name)
        return try await respond(name)
    }
}

@MainActor
final class ProjectsModel {
    static let shared = ProjectsModel()
    var projects: [Project] = []
}

// The Mac model forwards session navigation here; this harness only exercises its reads.
enum DashboardDestination { case sessionStats(session: JSON) }
@MainActor
final class Navigator {
    static let shared = Navigator()
    func push(_ destination: DashboardDestination) {}
}

func errorText(_ error: Error) -> String { String(describing: error) }
extension Error {
    var isCancellation: Bool { self is CancellationError || (self as? APIError)?.kind == .cancelled }
}

@main
struct ServerDashboardCheck {
    @MainActor
    static func until(_ ready: () -> Bool) async {
        for _ in 0..<10_000 {
            if ready() { return }
            await Task.yield()
        }
        preconditionFailure("Dashboard did not settle")
    }

    @MainActor
    static func main() async throws {
        let store = Store.shared
        defer { try? FileManager.default.removeItem(at: store.cache.directory) }
        let server: JSON = ["host": ["cpus": 4, "intervalMs": 5000], "sessions": ["open": 2]]
        let sessions: JSON = ["host": ["cpus": 4], "sessions": [["sessionId": "a", "cpuPercent": 25, "memoryBytes": 100]]]
        store.respond = { name in
            guard name == "server_stats" else { preconditionFailure("Overview waited for an auxiliary read") }
            return server
        }
        let model = ServerStatsModel()
        await model.load()
        precondition(model.server?.openSessions == 2 && store.calls == ["server_stats"])
        precondition(!model.sessionsLoaded && model.rows.isEmpty)

        for tab in [ServerDashboardTab.history, .disks] {
            model.tab = tab
            await model.load()
            precondition(store.calls.last == "server_stats" && model.charts.count == 2)
        }

        // Session errors and stale rows stay confined to their own tab.
        model.tab = .sessions
        store.respond = { _ in throw APIError(.network) }
        await model.load()
        precondition(model.error != nil && !model.sessionsLoaded && model.server?.openSessions == 2)
        model.tab = .overview
        precondition(model.error == nil)
        model.tab = .sessions
        store.respond = { name in
            precondition(name == "sessions_stats")
            return sessions
        }
        await model.load()
        precondition(model.error == nil && model.sessionsLoaded && model.rows.map(\.id) == ["a"])
        store.respond = { _ in throw APIError(.network) }
        await model.load()
        precondition(model.error != nil && model.rows.map(\.id) == ["a"])
        store.respond = { _ in ["host": ["cpus": 4], "sessions": []] }
        await model.load()
        precondition(model.error == nil && model.sessionsLoaded && model.rows.isEmpty)

        // A late refresh must not replace a more recent answer.
        model.tab = .overview
        var release: CheckedContinuation<JSON, Error>?
        store.respond = { _ in try await withCheckedThrowingContinuation { release = $0 } }
        let slow = Task { await model.load() }
        await until { release != nil }
        store.respond = { _ in ["host": ["cpus": 4], "sessions": ["open": 9]] }
        await model.load()
        release?.resume(returning: server)
        await slow.value
        precondition(model.server?.openSessions == 9)

        // Cancellation protects the last good reading even if the transport completes afterward.
        release = nil
        store.respond = { _ in try await withCheckedThrowingContinuation { release = $0 } }
        let cancelled = Task { await model.load() }
        await until { release != nil }
        cancelled.cancel()
        release?.resume(returning: server)
        await cancelled.value
        precondition(model.server?.openSessions == 9 && model.error == nil)

        store.respond = { _ in server }
        let beforePoll = store.calls.count
        let following = Task { await model.follow() }
        await until { store.calls.count > beforePoll }
        following.cancel()
        await following.value
        let afterPoll = store.calls.count
        model.tab = .sshServers
        await model.follow()
        await model.load()
        precondition(store.calls.count == afterPoll)

        // A token with only remote monitoring can still use the dashboard.
        store.offered = ["ssh_monitoring"]
        model.tab = .overview
        await model.follow()
        precondition(model.tab == .sshServers && model.tabs == [.sshServers])
        await model.follow()
        precondition(store.calls.count == afterPoll)
        print("Server dashboard loading, failures, cancellation and tab reads passed")
    }
}
