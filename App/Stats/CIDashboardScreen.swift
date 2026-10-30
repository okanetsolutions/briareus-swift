// CI/CD totals, trends and paged execution history on iPhone and iPad.
import SwiftUI
import Charts

struct CIDashboardScreen: View {
    @StateObject private var model = CIDashboardModel()
    @ObservedObject private var projects = ProjectsModel.shared

    var body: some View {
        List {
            CIDashboardFilters(query: $model.query, projects: projects.projects, clear: model.clearFilters)
            if let error = model.error {
                ErrorNotice(message: error)
                Button("Retry") { Task { await model.load() } }
            }
            if let reading = model.reading {
                Section("Totals") { StatTiles(tiles: reading.totals.tiles).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                if reading.totals.total == 0 {
                    ContentUnavailableView {
                        Label("No observed checks", systemImage: "checkmark.circle")
                    } description: {
                        Text("Try another project, source or window.")
                    } actions: {
                        if model.query.isFiltered { Button("Clear filters") { model.clearFilters() } }
                    }
                } else {
                    Section("Daily executions · UTC") { CIDailyChart(days: reading.daily) }
                    CIGroupSection(title: "Projects", groups: reading.repositories)
                    CIGroupSection(title: "Checks", groups: reading.checks)
                }
            }
            if model.loading { ProgressView("Loading CI/CD…") }
            if model.hasHistory {
                Section("Execution history") {
                    if let error = model.historyError {
                        ErrorNotice(message: error)
                        Button("Retry") { Task { await model.retryHistory() } }
                    }
                    ForEach(model.history.runs) { run in CIRunRow(run: run) }
                    if !model.loading && model.history.runs.isEmpty && model.historyError == nil {
                        Text("No executions in this window.").foregroundStyle(.secondary)
                    }
                    if model.history.nextOffset != nil {
                        Button(model.loadingMore ? "Loading…" : "Load more") { Task { await model.more() } }
                            .disabled(model.loading || model.loadingMore)
                    }
                    if model.history.truncated { Text("More executions exist; narrow the window or select a project.").foregroundStyle(.secondary) }
                }
            }
        }
        .task(id: model.query) { await model.load() }
        .refreshable { await model.load() }
    }
}

private struct CIGroupSection: View {
    let title: String
    let groups: [CIGroup]
    var body: some View {
        Section(title) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                    Text(group.metrics.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct CIRunRow: View {
    let run: CIRun
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = run.url { Link(run.name, destination: url) } else { Text(run.name) }
            Text(run.detail).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(run.result).foregroundStyle(Theme.color(run.tone))
                Text(run.duration)
                if let at = run.at { Text(at, style: .date) }
            }.font(.caption)
        }
    }
}

private struct CIDailyChart: View {
    let days: [CIGroup]
    var body: some View {
        Chart(days) { day in
            ForEach(CISeries.allCases, id: \.self) { series in
                BarMark(x: .value("UTC day", day.title), y: .value(series.label, series.count(day.metrics)))
                    .foregroundStyle(by: .value("Result", series.label))
            }
        }
        .chartForegroundStyleScale(domain: CISeries.allCases.map(\.label),
                                   range: CISeries.allCases.map { Theme.color($0.tone) })
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .frame(height: 210)
        .accessibilityLabel("Observed CI executions by UTC day")
    }
}
