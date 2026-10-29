// Resolve spoken errands against the live catalog before any paid start.
import Foundation

extension VoiceSession {
    func errandRequest(_ args: JSON, repo: String) async throws -> (operation: String, arguments: JSON) {
        let store = Store.shared
        let catalog = store.supports("actions") ? (try await store.call("actions"))["actions"] : .null
        guard let id = args["errand"].string, let number = args["number"].int,
              let action = Voice.offeredErrand(id, catalog: catalog, legacyReviews: store.supports("review")) else {
            throw APIError(.http, status: 400, message: "This server does not offer that errand.")
        }
        var branch: String?
        if action.operation == "review" {
            let board = try await store.call("pulls", ["repo": .string(repo)])
            guard let row = PullSummary.parseList(board["pulls"]).first(where: { $0.number == number }), !row.branch.isEmpty else {
                throw APIError(.http, status: 404, message: "Pull request #\(number) is not open on this project.")
            }
            branch = row.branch
        }
        return (action.operation, action.arguments(repo: repo, number: number, branch: branch))
    }
}
