// Both boards use the same pull request row, context menu, merge swipe and confirmation prompts on a phone.
import SwiftUI

struct BoardPullListRow: View {
    @ObservedObject var model: BoardPullActionsModel
    @ObservedObject private var feed: ProjectFeed
    @ObservedObject private var catalog = ErrandCatalog.shared
    let pull: PullSummary
    let stack: StackPosition?
    var issueStatus: [String?]

    init(model: BoardPullActionsModel, pull: PullSummary, stack: StackPosition?, issueStatus: [String?] = []) {
        self.model = model; self.pull = pull; self.stack = stack; self.issueStatus = issueStatus
        feed = model.feed
    }

    var body: some View {
        let actions = model.rowActions(for: pull)
        DestinationLink(destination: .pull(repo: model.repo, number: pull.number, stack: stack?.json, summary: pull.raw)) {
            BoardPullRow(pull: pull, stack: stack, repo: model.repo,
                         activeRuns: model.runs(on: pull.number).active,
                         suggested: actions.suggested?.label, issueStatus: issueStatus)
        }
        .contextMenu { BoardPullRowMenu(model: model, pull: pull, actions: actions) }
        .swipeActions(edge: .trailing) {
            if actions.canMerge {
                Button { model.mergeAsked = pull } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
                    .tint(Theme.accent).disabled(model.mergingNumber != 0)
            }
        }
    }
}

private struct BoardPullRowMenu: View {
    @ObservedObject var model: BoardPullActionsModel
    let pull: PullSummary
    let actions: BoardPullActions

    var body: some View {
        let errands = actions.menuErrands
        if !errands.isEmpty {
            Section("Errands") {
                ForEach(errands, id: \.id) { action in
                    Button(role: action.isDestructive ? .destructive : nil) {
                        model.errands.ask(action, number: pull.number, branch: pull.branch)
                    } label: {
                        Label(action.isSuggested(for: pull) ? "\(action.label) (suggested)" : action.label,
                              systemImage: action.isSuggested(for: pull) ? "sparkles" : errandSymbol(action.id))
                    }
                    .disabled(model.errands.busy || model.errands.uncertain)
                }
            }
        }
        if actions.canMerge {
            Button { model.mergeAsked = pull } label: {
                Label(model.mergingNumber == pull.number ? "Merging…" : "Merge…", systemImage: "arrow.triangle.merge")
            }
            .disabled(model.mergingNumber != 0)
        }
        if safeWebURL(pull.url) {
            Button { boardOpenWeb(pull.url) } label: { Label("Open on GitHub", systemImage: "safari") }
            Button { Pasteboard.copy(pull.url ?? "") } label: { Label("Copy link", systemImage: "link") }
        }
        if !pull.branch.isEmpty {
            Button { Pasteboard.copy(pull.branch) } label: { Label("Copy branch name", systemImage: "arrow.triangle.branch") }
        }
    }
}

struct BoardPullNotices: View {
    @ObservedObject var model: BoardPullActionsModel

    var body: some View {
        ErrandNotice(runner: model.errands, place: "in the project")
        if let note = model.mergeNote { Section { ErrorNotice(message: note) }.listRowBackground(Theme.row) }
    }
}

extension View {
    func boardPullPrompts(_ model: BoardPullActionsModel) -> some View { modifier(BoardPullPrompts(model: model)) }
}

private struct BoardPullPrompts: ViewModifier {
    @ObservedObject var model: BoardPullActionsModel

    func body(content: Content) -> some View {
        content
            .errandPrompts(model.errands)
            .alert(model.mergeAsked.map { "Merge #\($0.number)?" } ?? "",
                   isPresented: Binding(get: { model.mergeAsked != nil }, set: { if !$0 { model.mergeAsked = nil } }),
                   presenting: model.mergeAsked) { pull in
                Button("Merge") { model.merge(pull) }
                Button("Cancel", role: .cancel) {}
            } message: { pull in
                Text(boardPullMergeQuestion(pull))
            }
    }
}
