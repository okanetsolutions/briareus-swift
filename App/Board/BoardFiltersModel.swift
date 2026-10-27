// The board's saved author, reviewer, assignee and label pickers.
import Combine

/// The board's pickers, kept on disk per repository as the Mac keeps them. A board never filtered opens on the project's
/// configured author, while they have something open.
@MainActor
final class BoardFilters: ObservableObject {
    let repo: String
    @Published var pulls = BoardFilter()
    @Published var issues = BoardFilter()
    /// The filter the board last opened on, until the server has answered once and the picks are the user's.
    private var opening: BoardFilter?

    init(repo: String) {
        self.repo = repo
        if let saved = Store.shared.cache.value("pulls-filters:\(repo)") {
            pulls = BoardFilter(saved: saved["pulls"]); issues = BoardFilter(saved: saved["issues"])
        } else {
            opening = BoardFilter()
        }
    }

    /// A pick by the user: the board no longer opens on the author, and the picks are saved.
    func picked() {
        opening = nil
        Store.shared.cache.store(["pulls": pulls.saved, "issues": issues.saved], "pulls-filters:\(repo)")
    }
    /// A board shown before the server answered may be out of date about who has something open, so the server's answer
    /// opens it again, unless the pickers were touched meanwhile.
    func opened(_ board: JSON, answered: Bool) {
        guard let last = opening, board.isObject else { return }
        let f = BoardFilter.opening(author: board["author"].string, rows: PullSummary.parseList(board["pulls"]).map(BoardRow.init))
        if pulls == last { pulls = f }
        opening = answered ? nil : f
    }
}
