// Exercise both real CI dashboard models with fixed windows, overlapping reads and no live server.
import Foundation

@MainActor
final class Store {
    static let shared = Store()
    var client: APIClient?
    var offered: Set<String> = ["ci_stats", "ci_runs"]
    var calls: [(String, JSON)] = []
    var respond: (String, JSON) async throws -> JSON = { name, _ in
        name == "ci_stats" ? ["totals": ["total": 2]] : ["runs": [], "nextOffset": nil]
    }
    func supports(_ name: String) -> Bool { offered.contains(name) }
    func call(_ name: String, _ args: JSON) async throws -> JSON {
        precondition(offered.contains(name), "Called an unadvertised route")
        calls.append((name, args))
        return try await respond(name, args)
    }
}

@main
struct CIDashboardCheck {
    @MainActor
    static func until(_ ready: () -> Bool) async {
        for _ in 0..<10_000 {
            if ready() { return }
            await Task.yield()
        }
        preconditionFailure("CI dashboard did not settle")
    }

    @MainActor
    static func main() async throws {
        let store = Store.shared
        let model = CIDashboardModel()
        let run: JSON = ["id": "1", "repo": "o/r", "kind": "check_run", "name": "build"]
        store.respond = { name, args in
            if name == "ci_stats" { return ["totals": ["total": 2]] }
            return ["runs": .array([run]), "nextOffset": args["offset"].int == 0 ? 50 : nil]
        }
        await model.load()
        precondition(model.reading?.totals.total == 2 && model.history.runs.count == 1)
        precondition(!model.loading && !model.loadingMore && model.history.nextOffset == 50)
        await model.more()
        precondition(model.history.runs.count == 1 && model.history.nextOffset == nil)
        let initial = store.calls[0].1
        for call in store.calls {
            precondition(call.1["since"] == initial["since"] && call.1["until"] == initial["until"])
        }
        precondition(store.calls.last?.1["offset"].int == 50)

        // A failed aggregate does not hide history; a failed history does not hide totals.
        store.respond = { name, _ in
            if name == "ci_stats" { throw APIError(.network) }
            return ["runs": .array([run]), "nextOffset": nil]
        }
        await model.load()
        precondition(model.error != nil && model.history.runs.count == 1 && model.historyError == nil)
        store.respond = { name, _ in
            if name == "ci_runs" { throw APIError(.network) }
            return ["totals": ["total": 7]]
        }
        await model.load()
        precondition(model.reading?.totals.total == 7 && model.error == nil && model.historyError != nil)

        // A late response for the previous selection cannot replace the new window's totals or runs.
        var release: CheckedContinuation<JSON, Error>?
        store.respond = { _, _ in try await withCheckedThrowingContinuation { release = $0 } }
        let old = Task { await model.load() }
        await until { release != nil }
        model.query.repo = "other/repo"
        store.respond = { name, args in
            precondition(args["repo"] == "other/repo")
            return name == "ci_stats" ? ["totals": ["total": 9]] : ["runs": [], "nextOffset": nil]
        }
        await model.load()
        release?.resume(returning: ["totals": ["total": 1]])
        await old.value
        precondition(model.reading?.totals.total == 9 && model.history.runs.isEmpty)

        // A cancelled view discards even a transport that completes after cancellation.
        release = nil
        store.respond = { _, _ in try await withCheckedThrowingContinuation { release = $0 } }
        let cancelled = Task { await model.load() }
        await until { release != nil }
        cancelled.cancel()
        release?.resume(returning: ["totals": ["total": 100]])
        await cancelled.value
        precondition(model.reading == nil && model.error == nil && !model.loading)

        // Missing capabilities never issue requests, and a stats-only token never asks for history.
        store.offered = []
        let before = store.calls.count
        await model.load()
        precondition(store.calls.count == before && !model.loading)
        store.offered = ["ci_stats"]
        store.respond = { name, _ in
            precondition(name == "ci_stats")
            return ["totals": ["total": 0]]
        }
        await model.load()
        precondition(model.reading?.totals.total == 0 && model.history.runs.isEmpty)
        print("CI dashboard model checks passed")
    }
}
