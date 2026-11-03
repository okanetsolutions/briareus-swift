// The Issues tab's issues past the 100 a board lists: read a page at a time from `GET /issues` on Load more and listed
// after the board's own (Core's IssuePages decides where each page starts and which rows it adds).
import Foundation

@MainActor
final class IssuePagesModel: ObservableObject {
    let repo: String
    @Published private(set) var pages = IssuePages()
    @Published private(set) var loading = false
    /// Bumped by `reset`, so a page asked for before a refresh does not land after it.
    private var generation = 0

    init(repo: String) { self.repo = repo }

    /// The board stopped short, its pages have not ended, and the server has the route.
    func canLoadMore(board: JSON) -> Bool { pages.canLoadMore(board: board) && Store.shared.supports("issues") }

    /// The board stopped short and this server cannot read past it, so the list says it is cut.
    func cutShort(board: JSON) -> Bool { IssuePages.offered(board: board) && !Store.shared.supports("issues") }

    /// The board's issues followed by the ones read past them.
    func issues(after rows: [(summary: IssueSummary, raw: JSON)], board: JSON) -> [(summary: IssueSummary, raw: JSON)] {
        pages.issues(after: rows, answer: board)
    }

    /// The next page, or the one that failed again.
    func loadMore(board: JSON) async {
        guard !loading, canLoadMore(board: board) else { return }
        let mine = generation
        loading = true
        pages.reading()
        defer { if mine == generation { loading = false } }
        do {
            let answer = try await Store.shared.call("issues", pages.query(repo: repo, board: board))
            guard mine == generation else { return }
            pages.receive(IssuesPage(answer), board: board)
        } catch {
            guard mine == generation else { return }
            if let said = failure(error) { pages.fail(said) }
        }
    }

    /// A pull to refresh reads the board afresh; its pages start again after it.
    func reset() {
        generation += 1
        pages = IssuePages()
        loading = false
    }
}
