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
            GlobalBoardTabs(model: model)
            GlobalPullsFilters(model: model)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let error = model.state.error { Notice(message: error.description) }
                    ForEach(model.state.projects, id: \.project.repo) { entry in
                        if let error = entry.error { Notice(message: "\(entry.project.repo): \(error.description)") }
                    }
                    GlobalBoardList(model: model)
                    if model.state.loading && !model.state.loaded { LoadingNote(text: "Loading pull requests…") }
                    else if model.state.loaded && model.shownCount == 0 { EmptyNote(title: model.emptyTitle) }
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
            buttons.append(HeaderButton(glyph: "person.crop.circle", label: BoardEdits.login.map { "Reviewing as \($0)" } ?? "Set my GitHub login…",
                                        action: { model.setLogin() }))
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
            (.review, model.state.loaded ? "✓ Review List \(model.reviewRows.count)" : "✓ Review List")
        ]
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(labels, id: \.0) { tab, label in BoardTabButton(label: label, active: model.tab == tab) { model.tab = tab } }
                Spacer(minLength: 0)
            }
            BoardRule()
        }
        .padding(.horizontal, 18)
    }
}

/// The rows of the tab on show.
private struct GlobalBoardList: View {
    @ObservedObject var model: GlobalPullsModel

    var body: some View {
        switch model.tab {
        case .pulls, .review:
            ForEach(model.tab == .pulls ? model.rows : model.reviewRows) { row in
                GlobalPullsRow(row: row) { model.open(row) }
            }
        case .issues:
            ForEach(model.state.issueRefusals, id: \.project.repo) { refused in
                Notice(message: "\(refused.project.repo): GitHub would not read this repository’s issues. \(refused.message)")
            }
            ForEach(model.issueRows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.project.repo).font(Theme.caption).foregroundStyle(Theme.accent).lineLimit(1)
                    IssueRowView(issue: row.issue, repo: row.project.repo) { model.open(row) }
                }
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
        TextField(model.tab == .issues ? "Search all issues" : "Search all pull requests", text: $model.filter.query)
            .dashField().accessibilityLabel(model.tab == .issues ? "Search all issues" : "Search all pull requests")
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

private struct GlobalPullsRow: View {
    let row: GlobalPullRow
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.project.repo).font(Theme.caption).foregroundStyle(Theme.accent).lineLimit(1)
            PullRow(pull: row.pull, stack: row.stack, repo: row.project.repo, action: open)
        }
    }
}
