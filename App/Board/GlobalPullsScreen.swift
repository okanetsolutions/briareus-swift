// The open pull requests from every accessible project, opening the same detail screen as a project's board.
import SwiftUI

struct GlobalPullsScreen: View {
    @StateObject private var model = GlobalPullsModel()

    var body: some View {
        List {
            GlobalPullsFilters(model: model)
            if let error = model.state.error {
                Section { ErrorNotice(message: error.description) }.listRowBackground(Theme.row)
            }
            ForEach(model.state.projects, id: \.project.repo) { entry in
                if let error = entry.error {
                    Section(entry.project.repo) { ErrorNotice(message: error.description) }.listRowBackground(Theme.row)
                }
            }
            Section {
                ForEach(model.rows) { row in
                    DestinationLink(destination: .pull(repo: row.project.repo, number: row.pull.number,
                                                       stack: row.stack?.json, summary: row.pull.raw)) {
                        GlobalPullsRow(row: row)
                    }
                }
            }
            if model.state.loading {
                ProgressView("Loading pull requests…").frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if model.state.loaded && model.rows.isEmpty {
                ContentUnavailableView(model.emptyTitle, systemImage: "arrow.triangle.pull")
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.canvas)
        .navigationTitle("Pull requests")
        .searchable(text: $model.filter.query, prompt: "Search all pull requests")
        .refreshable { await model.load(fresh: true) }
        .task { await poll(every: 60) { await model.load() } }
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
            if model.filter.isOn { Button("Clear filters") { model.clearFilters() } }
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
