// The board across every accessible project, as a project's board on a phone: the pull requests, issues and Review List
// behind a segmented control, opening the same detail screens as a project's board.
import SwiftUI

struct GlobalPullsScreen: View {
    @StateObject private var model = GlobalPullsModel()
    /// The Review List's login alert and what is typed in it.
    @State private var loginAsked = false
    @State private var loginText = ""

    var body: some View {
        List {
            GlobalBoardTabPicker(model: model)
            GlobalPullsFilters(model: model) { loginText = GitHubLogin.current ?? ""; loginAsked = true }
            if let error = model.state.error {
                Section { ErrorNotice(message: error.description) }.listRowBackground(Theme.row)
            }
            ForEach(model.state.projects, id: \.project.repo) { entry in
                if let error = entry.error {
                    Section(entry.project.repo) { ErrorNotice(message: error.description) }.listRowBackground(Theme.row)
                }
            }
            GlobalBoardRows(model: model)
            if model.state.loading && !model.state.loaded {
                ProgressView("Loading pull requests…").frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if model.state.loaded && model.shownCount == 0 {
                ContentUnavailableView(model.emptyTitle, systemImage: model.tab == .issues ? "smallcircle.filled.circle" : "arrow.triangle.pull")
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.canvas)
        .navigationTitle("All projects")
        .searchable(text: $model.filter.query, prompt: model.tab == .issues ? "Search all issues" : "Search all pull requests")
        .refreshable { await model.load(fresh: true) }
        .task { await poll(every: 60) { await model.load() } }
        .alert("Your GitHub login", isPresented: $loginAsked) {
            TextField("Login", text: $loginText).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save") { model.saveLogin(loginText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Review List shows the pull requests waiting on this GitHub user's review.")
        }
    }
}

/// The project board's segmented control, across every project.
private struct GlobalBoardTabPicker: View {
    @ObservedObject var model: GlobalPullsModel

    var body: some View {
        Picker("Show", selection: $model.tab) {
            Text("PRs (\(model.rows.count))").tag(GlobalBoardTab.pulls)
            Text("Issues (\(model.issueRows.count))").tag(GlobalBoardTab.issues)
            Text("Review List (\(model.reviewRows.count))").tag(GlobalBoardTab.review)
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }
}

private struct GlobalPullsFilters: View {
    @ObservedObject var model: GlobalPullsModel
    var askLogin: () -> Void

    var body: some View {
        Section {
            Picker("Project", selection: $model.filter.repo) {
                Text("All projects").tag("")
                ForEach(model.state.projects, id: \.project.repo) { entry in
                    Text(entry.project.title).tag(entry.project.repo)
                }
            }
            Text(model.state.subtitle).font(.footnote).foregroundStyle(.secondary)
            if model.tab == .review {
                Button(action: askLogin) {
                    Label(GitHubLogin.current.map { "Reviewing as \($0)" } ?? "Set my GitHub login…", systemImage: "person.crop.circle")
                }
            }
            if model.filter.isOn { Button("Clear filters") { model.clearFilters() } }
        }
        .listRowBackground(Theme.row)
    }
}

/// The rows of the tab on show.
private struct GlobalBoardRows: View {
    @ObservedObject var model: GlobalPullsModel

    var body: some View {
        Section {
            switch model.tab {
            case .pulls, .review:
                ForEach(model.tab == .pulls ? model.rows : model.reviewRows) { row in
                    DestinationLink(destination: .pull(repo: row.project.repo, number: row.pull.number,
                                                       stack: row.stack?.json, summary: row.pull.raw)) {
                        GlobalPullsRow(row: row)
                    }
                }
            case .issues:
                ForEach(model.state.issueRefusals, id: \.project.repo) { refused in
                    ErrorNotice(message: "\(refused.project.repo): GitHub would not read this repository’s issues. \(refused.message)")
                }
                ForEach(model.issueRows) { row in
                    DestinationLink(destination: .issue(repo: row.project.repo, issue: row.raw)) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.project.repo).font(.caption).foregroundStyle(Theme.accent).lineLimit(1)
                            BoardIssueRow(issue: row.issue, repo: row.project.repo)
                        }
                    }
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
