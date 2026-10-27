// The board across every accessible project, opened from the All entry as a project's row opens its board: the pull
// requests, issues and Review List tabs, using the board's rows and detail navigation.
import SwiftUI

struct GlobalPullsScreen: View {
    @StateObject private var model: GlobalPullsModel

    init() {
        _model = StateObject(wrappedValue: BoardModels.model("global-pulls") { GlobalPullsModel() })
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "All projects", subtitle: model.state.subtitle, buttons: headerButtons)
            GlobalBoardTabs(model: model).padding(.horizontal, Theme.paneMargin)
            GlobalPullsFilters(model: model)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let error = model.state.error { Notice(message: error.description) }
                    ForEach(model.state.projects, id: \.project.repo) { entry in
                        if let error = entry.error { Notice(message: "\(entry.project.repo): \(error.description)") }
                        if let board = model.boards[entry.project.repo] {
                            BoardPullWriteNotice(model: board, repo: entry.project.repo)
                        }
                    }
                    GlobalBoardList(model: model)
                    if model.state.loading && !model.state.loaded { LoadingNote(text: model.tab.loadingText) }
                    else if model.state.loaded && model.shown.count(model.tab) == 0 { EmptyNote(title: model.emptyTitle) }
                }
                .padding(18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .task { await poll(every: 60) { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in Task { await model.load(fresh: true) } }
        .onDisappear { BoardModels.release("global-pulls") }
    }

    private var headerButtons: [HeaderButton] {
        var buttons: [HeaderButton] = []
        if model.tab == .review {
            buttons.append(BoardEdits.reviewLoginButton { model.loginChanged() })
        }
        buttons.append(HeaderButton(glyph: "arrow.clockwise", label: "Refresh", enabled: !model.state.loading,
                                    action: { Task { await model.load(fresh: true) } }))
        return buttons
    }
}

/// The project board's list tabs, across every project.
private struct GlobalBoardTabs: View {
    @ObservedObject var model: GlobalPullsModel

    var body: some View {
        let labels: [(GlobalBoardTab, String)] = [
            (.pulls, "⇅ Pull requests"), (.issues, "⊙ Issues"),
            (.review, boardReviewTabLabel(count: model.state.loaded ? model.totals.count(.review) : nil))
        ]
        BoardTabStrip(labels: labels, active: model.tab) { model.tab = $0 }
    }
}

/// The rows of the tab on show.
private struct GlobalBoardList: View {
    @ObservedObject var model: GlobalPullsModel

    var body: some View {
        switch model.tab {
        case .pulls, .review:
            ForEach(model.tab == .pulls ? model.shown.pulls : model.shown.review) { row in
                if let board = model.boards[row.project.repo] {
                    BoardPullListRow(model: board, pull: row.pull, stack: row.stack) { model.open(row) }
                }
            }
        case .issues:
            ForEach(model.shown.issueRefusals, id: \.project.repo) { Notice(message: $0.notice) }
            ForEach(model.shown.issues) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.project.repo).font(Theme.caption).foregroundStyle(Theme.accent).lineLimit(1)
                    IssueRowView(issue: row.issue, repo: row.project.repo) { model.open(row) }
                }
            }
            ForEach(model.shown.issueTruncations, id: \.project.repo) {
                Text($0.notice).font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GlobalPullsFilters: View {
    @ObservedObject var model: GlobalPullsModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { search; project }
            VStack(alignment: .leading, spacing: 10) { search; project }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var search: some View {
        TextField(model.tab.searchPrompt, text: $model.filter.query)
            .dashField().accessibilityLabel(model.tab.searchPrompt)
    }

    private var project: some View {
        HStack(spacing: 8) {
            Picker("Project", selection: $model.filter.repo) {
                Text("All projects").tag("")
                ForEach(model.state.projects, id: \.project.repo) { entry in
                    Text(entry.project.title).tag(entry.project.repo)
                }
            }
            .labelsHidden().accessibilityLabel("Project")
            if model.filter.isOn { Button("Clear filters") { model.clearFilters() }.dashButton(.bordered) }
        }
    }
}
