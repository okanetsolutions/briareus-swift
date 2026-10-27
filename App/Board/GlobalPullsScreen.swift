// The board across every accessible project, as a project's board on a phone: the pull requests, issues and Review List
// behind a segmented control, opening the same detail screens as a project's board.
import SwiftUI

struct GlobalPullsScreen: View {
    @StateObject private var model = GlobalPullsModel()

    var body: some View {
        List {
            GlobalBoardTabPicker(model: model)
            GlobalPullsFilters(model: model)
            if let error = model.state.error {
                Section { ErrorNotice(message: error.description) }.listRowBackground(Theme.row)
            }
            ForEach(model.state.projects, id: \.project.repo) { entry in
                if let error = entry.error {
                    Section(entry.project.repo) { ErrorNotice(message: error.description) }.listRowBackground(Theme.row)
                }
            }
            if model.state.loading {
                ProgressView(model.tab.loadingText).frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if model.state.loaded && model.shown.count(model.tab) == 0 {
                ContentUnavailableView(model.emptyTitle, systemImage: model.tab.symbol)
                    .listRowBackground(Color.clear)
            }
            GlobalBoardList(model: model)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.canvas)
        .navigationTitle("All projects")
        .searchable(text: $model.filter.query, prompt: model.tab.searchPrompt)
        .refreshable { await model.load(fresh: true) }
        .task { await poll(every: 60) { await model.load() } }
    }
}

/// The project board's segmented control, across every project.
private struct GlobalBoardTabPicker: View {
    @ObservedObject var model: GlobalPullsModel

    var body: some View {
        Picker("Show", selection: $model.tab) {
            Text("PRs (\(model.totals.count(.pulls)))").tag(GlobalBoardTab.pulls)
            Text("Issues (\(model.totals.count(.issues)))").tag(GlobalBoardTab.issues)
            Text("Review List (\(model.totals.count(.review)))").tag(GlobalBoardTab.review)
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }
}

private struct GlobalPullsFilters: View {
    @ObservedObject var model: GlobalPullsModel

    var body: some View {
        Section {
            Picker("Project", selection: $model.filter.repo) {
                Text("All projects").tag("")
                ForEach(model.state.projects, id: \.project.repo) { entry in
                    Text(entry.project.title).tag(entry.project.repo)
                }
            }
            Text(model.state.subtitle).font(.footnote).foregroundStyle(.secondary)
            if model.tab == .review { ReviewLoginButton { model.loginChanged() } }
            if model.filter.isOn { Button("Clear filters") { model.clearFilters() } }
        }
        .listRowBackground(Theme.row)
    }
}

/// The rows of the tab on show.
private struct GlobalBoardList: View {
    @ObservedObject var model: GlobalPullsModel

    var body: some View {
        Section {
            switch model.tab {
            case .pulls, .review:
                ForEach(model.tab == .pulls ? model.shown.pulls : model.shown.review) { row in
                    DestinationLink(destination: .pull(repo: row.project.repo, number: row.pull.number,
                                                       stack: row.stack?.json, summary: row.pull.raw)) {
                        GlobalPullsRow(row: row)
                    }
                }
            case .issues:
                ForEach(model.shown.issueRefusals, id: \.project.repo) { ErrorNotice(message: $0.notice) }
                ForEach(model.shown.issues) { row in
                    DestinationLink(destination: .issue(repo: row.project.repo, issue: row.raw)) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.project.repo).font(.caption).foregroundStyle(Theme.accent).lineLimit(1)
                            BoardIssueRow(issue: row.issue, repo: row.project.repo)
                        }
                    }
                }
                ForEach(model.shown.issueTruncations, id: \.project.repo) {
                    Text($0.notice).font(.footnote).foregroundStyle(Theme.muted)
                }
            }
        }
        .listRowBackground(Theme.row)
    }
}

private struct GlobalPullsRow: View {
    let row: GlobalPullRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(row.project.repo).font(.caption).foregroundStyle(Theme.accent).lineLimit(1)
            BoardPullRow(pull: row.pull, stack: row.stack, repo: row.project.repo)
        }
    }
}
