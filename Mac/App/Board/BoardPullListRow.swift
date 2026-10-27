// The project and cross-project boards share a pull request row and its errand, merge and run buttons.
import SwiftUI

struct BoardPullListRow: View {
    @ObservedObject var model: BoardModel
    let pull: PullSummary
    let stack: StackPosition?
    var open: () -> Void

    var body: some View {
        PullRow(pull: pull, stack: stack, repo: model.repo, running: model.runActiveOn(pull.number),
                issueStatus: model.issueStatus.statuses(pull), action: open) {
            BoardPullRowButtons(model: model, pull: pull)
        }
    }
}

private struct BoardPullRowButtons: View {
    @ObservedObject var model: BoardModel
    let pull: PullSummary

    var body: some View {
        let actions = model.rowActions(for: pull)
        let runs = model.runsOn(pull.number)
        if !actions.errands.isEmpty || runs > 0 || actions.canMerge {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(actions.errands, id: \.id) { action in
                    let starting = model.busy && model.startingNumber == pull.number && model.startingID == action.id
                    Button { model.act(pull, action) } label: {
                        if starting { Text(verbatim: "Starting…") } else { ErrandLabel(id: action.id, label: action.label) }
                    }
                    .dashButton(action.isSuggested(for: pull) ? .prominent : .bordered)
                    .disabled(model.busy || model.uncertain)
                    .help(action.hint)
                }
                if actions.canMerge {
                    Button(model.mergingNumber == pull.number ? "Merging…" : "↳ Merge") { model.merge(pull) }
                        .dashButton(.bordered)
                        .disabled(model.mergingNumber != 0 || model.busy)
                        .help("Squash-merge this pull request on GitHub")
                }
                if runs > 0 {
                    Button(String("\(runs) run\(runs == 1 ? "" : "s") ›")) { model.openRuns(pull) }.dashButton(.plain)
                }
            }
            .padding(.top, 8)
        }
    }
}

/// A write's outcome stays visible even when the affected pull request has left the list after merging.
struct BoardPullWriteNotice: View {
    @ObservedObject var model: BoardModel
    var repo: String? = nil

    var body: some View {
        if let error = model.writeError {
            Notice(message: repo.map { "\($0): \(error)" } ?? error)
            if model.uncertain {
                Text("The request may have completed. Refresh (F5) and look for its conversation in the project before starting another agent.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            Spacer().frame(height: 10)
        }
    }
}
