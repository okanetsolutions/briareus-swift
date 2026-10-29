// Voice errands follow the same server catalog as the board, including the new Claude review action.
import Foundation

extension Voice {
    static func offeredErrand(_ id: String, catalog: JSON, legacyReviews: Bool) -> BoardAction? {
        guard errands.contains(id) else { return nil }
        let listed = catalog.items.contains { $0["id"].string == id }
        guard listed || (id == "review" && legacyReviews) else { return nil }
        let action = BoardAction.offered(catalog: catalog, pull: nil, failedChecks: 1).first { $0.id == id }
        if action?.operation == "review" && !legacyReviews { return nil }
        return action
    }
}
