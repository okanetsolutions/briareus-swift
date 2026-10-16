// The saved prompts (core /prompts) on a phone and in the car: a project's own and the ones offered everywhere, read once
// per project and kept while the app runs, as the Mac's 📚 keeps them. The list's order and how a chosen one joins the
// box are Core's `SavedPrompt`.
import Foundation

@MainActor
final class SavedPrompts {
    static let shared = SavedPrompts()
    private var byRepo: [String: [SavedPrompt]] = [:]

    /// Whether the server keeps saved prompts at all.
    static var offered: Bool { Store.shared.supports("prompts") }

    /// The project's prompts and the ones offered everywhere; none when the server keeps none or the read failed.
    func list(_ repo: String?) async -> [SavedPrompt] {
        guard Self.offered else { return [] }
        let key = repo ?? ""
        if let l = byRepo[key] { return l }
        var args: JSON = [:]
        if let repo { args["repo"] = .string(repo) }
        guard let v = try? await Store.shared.call("prompts", args) else { return [] }
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

    init(repo: String?) { self.repo = repo }

    func load() async { prompts = await SavedPrompts.shared.list(repo) }
}
