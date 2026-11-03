// The board's Issues tab: the open issues the filters keep, sub-issues under their epic, and, when the board listed only
// its first 100, Load more for the next page from the server (a failed one read again), with why the last read failed.
import SwiftUI

struct BoardIssueList: View {
    @ObservedObject var model: BoardModel
    let filter: BoardFilter
    /// How many rows the filters keep, as the count above the list says.
    let shown: Int

    var body: some View {
        if let refused = model.board["issuesError"].string {
            BoardBox(padding: 12, radius: 10) {
                Text("GitHub would not read this repository’s issues with the server’s token. A fine-grained token needs Issues: read. The pull requests are unaffected.")
                    .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Notice(message: refused).padding(.top, 6)
            }
        } else {
            let issues = model.listedIssues
            rows(issues)
            more
            if model.issuesCutShort {
                Text("This repository has more open issues; only the most recently updated are listed.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !boardShowsLoading(loaded: model.loaded, refreshing: model.refreshing) && shown == 0 && model.error == nil {
                Text(issues.isEmpty ? "No open issues." : "No issues match the filters.").font(Theme.footnote).foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder private func rows(_ issues: [(summary: IssueSummary, raw: JSON)]) -> some View {
        let visible = issues.indices.filter { filter.passes(BoardRow(issues[$0].summary)) }
        let summaries = visible.map { issues[$0].summary }
        let nested = issuesFolded(issuesNested(summaries, repo: model.repo), summaries, folded: model.foldedEpics)
        ForEach(Array(nested.enumerated()), id: \.offset) { _, row in
            let issue = issues[visible[row.index]]
            let depth = min(row.depth, 4)
            let number = issue.summary.number
            IssueRowView(issue: issue.summary, repo: model.repo, nested: depth > 0,
                         folded: row.children > 0 ? model.foldedEpics.contains(number) : nil,
                         fold: { if model.foldedEpics.remove(number) == nil { model.foldedEpics.insert(number) } }) {
                model.openIssue(issue.raw)
            }
                .padding(.leading, CGFloat(depth) * 18)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder private var more: some View {
        if let error = model.issuePages.error { Notice(message: error).padding(.bottom, 6) }
        if model.canLoadMoreIssues {
            Button(model.issuePagesLoading ? "Loading\u{2026}" : model.issuePages.error == nil ? "Load more" : "Retry") { model.loadMoreIssues() }
                .dashButton(.bordered).disabled(model.issuePagesLoading).padding(.bottom, 8)
        }
    }
}
