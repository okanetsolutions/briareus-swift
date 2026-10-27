// The open pull requests from every accessible project, using the board's rows and pull detail navigation.
import SwiftUI

struct GlobalPullsScreen: View {
    @StateObject private var model: GlobalPullsModel

    init() {
        _model = StateObject(wrappedValue: BoardModels.model("global-pulls") { GlobalPullsModel() })
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Pull requests", subtitle: model.state.subtitle, buttons: [
                HeaderButton(glyph: "arrow.clockwise", label: "Refresh", enabled: !model.state.loading,
                             action: { Task { await model.load(fresh: true) } })
            ])
            GlobalPullsFilters(model: model)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let error = model.state.error { Notice(message: error.description) }
                    ForEach(model.state.projects, id: \.project.repo) { entry in
                        if let error = entry.error { Notice(message: "\(entry.project.repo): \(error.description)") }
                    }
                    ForEach(model.rows) { row in
                        GlobalPullsRow(row: row) { model.open(row) }
                    }
                    if model.state.loading { LoadingNote(text: "Loading pull requests…") }
                    else if model.state.loaded && model.rows.isEmpty { EmptyNote(title: model.emptyTitle) }
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
        TextField("Search all pull requests", text: $model.filter.query)
            .dashField().accessibilityLabel("Search all pull requests")
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
