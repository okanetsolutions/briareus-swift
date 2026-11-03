// The end of the Issues tab when the board listed only its first 100 open issues: Load more reads the next page from the
// server (and a failed one again), with why the last read failed above it.
import SwiftUI

struct BoardIssuesMore: View {
    @ObservedObject var model: IssuePagesModel
    let board: JSON

    var body: some View {
        if let error = model.pages.error { ErrorNotice(message: error) }
        if model.canLoadMore(board: board) {
            Button { Task { await model.loadMore(board: board) } } label: {
                HStack {
                    Text(model.pages.error == nil ? "Load more issues" : "Retry")
                    if model.loading { Spacer(); ProgressView() }
                }
            }
            .disabled(model.loading)
        }
    }
}
