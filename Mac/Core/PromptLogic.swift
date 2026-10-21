// The saved prompts (core /prompts): a project's own and the ones offered everywhere, as every app lists them, and how one
// joins text already typed. The Mac's composers and errand dialog, the iPhone's errand sheet and CarPlay's errands share it.
import Foundation

/// One saved prompt: what its menu row says and what it puts in the box.
struct SavedPrompt: Equatable, Sendable, Identifiable {
    /// The server's id; nil on one it sent without, which can be inserted but not edited or deleted.
    var serverID: Int?
    var title: String
    var body: String
    /// The project it belongs to; nil when it is offered on every project.
    var repo: String?
    var sortOrder: Double?

    var id: String { serverID.map(String.init) ?? "\(repo ?? ""):\(title)" }
    /// Offered on every project rather than one.
    var everywhere: Bool { repo == nil }

    init(serverID: Int? = nil, title: String, body: String, repo: String? = nil, sortOrder: Double? = nil) {
        self.serverID = serverID; self.title = title; self.body = body; self.repo = repo; self.sortOrder = sortOrder
    }

    /// Nil for an entry without a title or a body.
    init?(_ j: JSON) {
        guard let title = j["title"].nonEmpty, let body = j["body"].string else { return nil }
        self.init(serverID: j["id"].truncatedInt, title: title, body: body, repo: j["repo"].nonEmpty, sortOrder: j["sortOrder"].number)
    }

    /// The `prompts` answer as the menus list it: by sort order, those without one last, then by title.
    static func list(_ v: JSON) -> [SavedPrompt] {
        v["prompts"].items.compactMap(SavedPrompt.init)
            .sorted { ($0.sortOrder ?? .infinity, $0.title) < ($1.sortOrder ?? .infinity, $1.title) }
    }

    /// The box's text once this prompt is chosen: the prompt alone in an empty box, else after what is there, a blank line
    /// between.
    func inserted(into text: String) -> String {
        text.cTrimmed.isEmpty ? body : text + "\n\n" + body
    }
}
