// Runs the phone's real prompt loader against a controllable Store, without a server or UI.
// swiftc -parse-as-library Mac/Core/*.swift App/Shared/SavedPrompts.swift scripts/check_saved_prompts.swift -o /tmp/check-saved-prompts
import Foundation

@MainActor
final class Store {
    static let shared = Store()
    var client: APIClient?
    var read: () async throws -> JSON = { [:] }
    func supports(_ operation: String) -> Bool { true }
    func call(_ operation: String, _ arguments: JSON) async throws -> JSON { try await read() }
}

func failure(_ error: Error) -> String? {
    error is CancellationError ? nil : error.localizedDescription
}

@main
struct SavedPromptsChecks {
    @MainActor
    static func main() async throws {
        let store = Store.shared
        let address = ServerAddress("https://example.com")!
        let a = try APIClient(address: address, token: "brm_" + String(repeating: "a", count: 43))
        let b = try APIClient(address: address, token: "brm_" + String(repeating: "b", count: 43))
        let answer: JSON = ["prompts": [["title": "A", "body": "Only A's connection"]]]
        let loader = SavedPrompts()
        var reads = 0
        store.client = a
        store.read = { reads += 1; return answer }
        let first = try await loader.list("o/r")
        let cached = try await loader.list("o/r")
        precondition(first == cached && first.count == 1 && reads == 1)
        store.client = nil
        do { _ = try await loader.list("o/r"); preconditionFailure("Disconnected cache escaped") }
        catch is CancellationError {}
        store.client = b
        store.read = { reads += 1; return ["prompts": []] }
        let next = try await loader.list("o/r")
        precondition(next.isEmpty && reads == 2)

        // Switch connections while A's request is suspended, and let B fill its cache first.
        var pending: CheckedContinuation<JSON, Error>?
        store.client = a
        store.read = { try await withCheckedThrowingContinuation { pending = $0 } }
        let old = Task { try await loader.list("o/r") }
        while pending == nil { await Task.yield() }
        store.client = b
        store.read = { ["prompts": []] }
        _ = try await loader.list("o/r")
        pending!.resume(returning: answer)
        do { _ = try await old.value; preconditionFailure("Old result escaped") }
        catch is CancellationError {}
        let stillB = try await loader.list("o/r")
        precondition(stillB.isEmpty)

        // A failed read stays an error; retry can recover, and a successful empty list is distinct.
        let model = SavedPromptsModel(repo: "new/repo")
        store.read = { throw URLError(.timedOut) }
        await model.load()
        precondition(model.error != nil && model.prompts.isEmpty && !model.loading)
        pending = nil
        store.read = { try await withCheckedThrowingContinuation { pending = $0 } }
        let retry = Task { await model.load() }
        while pending == nil { await Task.yield() }
        precondition(model.loading && model.error == nil)
        pending!.resume(returning: answer)
        await retry.value
        precondition(!model.loading && model.error == nil && model.prompts.count == 1)
        let empty = SavedPromptsModel(repo: "empty/repo")
        store.read = { ["prompts": []] }
        await empty.load()
        precondition(!empty.loading && empty.error == nil && empty.prompts.isEmpty)
        print("Saved prompt connection, stale response, failure and retry checks passed")
    }
}
