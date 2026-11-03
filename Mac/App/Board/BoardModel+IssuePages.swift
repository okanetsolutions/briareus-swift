// The Issues tab's issues past the 100 a board lists, read a page at a time from `GET /issues` on Load more (Core's
// IssuePages decides where each page starts and which rows it adds).
import Foundation

extension BoardModel {
    /// The board's issues followed by the ones read past them: what the Issues tab lists and filters.
    var listedIssues: [(summary: IssueSummary, raw: JSON)] { issuePages.issues(after: issues, answer: board) }
    /// The board stopped short, its pages have not ended, and the server has the route.
    var canLoadMoreIssues: Bool { issuePages.canLoadMore(board: board, routed: Store.shared.supports("issues")) }
    /// The board stopped short and nothing reads past it, so the list says it is cut.
    var issuesCutShort: Bool { issuePages.cutShort(board: board, routed: Store.shared.supports("issues")) }
    /// Why the last page failed, while Load more can read it again.
    var issuePagesError: String? { issuePages.retryError(board: board, routed: Store.shared.supports("issues")) }

    /// The next page, or the one that failed again.
    func loadMoreIssues() {
        guard !issuePagesLoading, canLoadMoreIssues else { return }
        let mine = issuePagesGen, board = self.board, query = issuePages.query(repo: repo, board: board)
        issuePagesLoading = true
        issuePages.reading()
        Task {
            let r = await boardCall("issues", query)
            guard mine == issuePagesGen else { return }
            issuePagesLoading = false
            switch r {
            case .success(let v): issuePages.receive(IssuesPage(v), board: board)
            case .failure(let e): if e.kind != .cancelled { issuePages.fail(e.description) }
            }
        }
    }

    /// A refresh reads the board afresh; its pages start again after it.
    func resetIssuePages() {
        issuePagesGen += 1
        issuePages = IssuePages()
        issuePagesLoading = false
    }
}
