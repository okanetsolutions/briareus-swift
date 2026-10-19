// The saved prompts (core /prompts) on a phone and in the car: a project's own and the ones offered everywhere, read once
// per project and kept for the active connection, as the Mac's 📚 keeps them. The list's order and how a chosen one joins the
// box are Core's `SavedPrompt`.
import Foundation
import Combine

@MainActor
final class SavedPrompts {
    static let shared = SavedPrompts()
    private weak var client: APIClient?
    private var byRepo: [String: [SavedPrompt]] = [:]

    /// Whether the server keeps saved prompts at all.
    static var offered: Bool { Store.shared.supports("prompts") }

    /// The project's prompts and the ones offered everywhere; a failed or abandoned read throws.
    func list(_ repo: String?) async throws -> [SavedPrompt] {
        let store = Store.shared
        guard let client = store.client else { throw CancellationError() }
        if self.client !== client { byRepo = [:]; self.client = client }
        guard Self.offered else { return [] }
        let key = repo ?? ""
        if let l = byRepo[key] { return l }
        var args: JSON = [:]
        if let repo { args["repo"] = .string(repo) }
        let v = try await store.call("prompts", args)
        try Task.checkCancellation()
        guard store.client === client else { throw CancellationError() }
        let l = SavedPrompt.list(v)
        byRepo[key] = l
        return l
    }
}

/// The prompts a sheet offers for its box, loaded when it appears.
@MainActor
final class SavedPromptsModel: ObservableObject {
    let repo: String?
    @Published private(set) var prompts: [SavedPrompt] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    init(repo: String?) { self.repo = repo }

    func load() async {
        guard !loading else { return }
        loading = true; error = nil; prompts = []
        defer { loading = false }
        do { prompts = try await SavedPrompts.shared.list(repo) }
        catch { self.error = failure(error) }
    }
}
