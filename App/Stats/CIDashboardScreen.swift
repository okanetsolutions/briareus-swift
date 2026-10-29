// CI/CD totals, trends and paged execution history on iPhone and iPad.
import SwiftUI
import Charts

struct CIDashboardScreen: View {
    @StateObject private var model = CIDashboardModel()
    @ObservedObject private var projects = ProjectsModel.shared

    var body: some View {
        List {
            Section {
                Picker("Window", selection: $model.query.days) {
                    ForEach([7, 30, 90], id: \.self) { Text("\($0) days").tag($0) }
                }
                Picker("Project", selection: $model.query.repo) {
                    Text("All projects").tag("")
                    ForEach(projects.projects, id: \.repo) { Text($0.title).tag($0.repo) }
                }
                Picker("Source", selection: $model.query.kind) {
                    ForEach(CIKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Observed GitHub checks only; earlier history may be incomplete. Daily totals use UTC. Durations are execution time, not billed minutes.")
            }
            if let error = model.error {
                ErrorNotice(message: error)
                Button("Retry") { Task { await model.load() } }
            }
            if let reading = model.reading {
                Section("Totals") { StatTiles(tiles: reading.totals.tiles).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                if reading.totals.total == 0 {
                    ContentUnavailableView("No observed checks", systemImage: "checkmark.circle", description: Text("Try another project, source or window."))
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
                        Button("Retry") { Task { await model.load() } }
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
            BarMark(x: .value("UTC day", day.title), y: .value("Passed", day.metrics.succeeded))
                .foregroundStyle(by: .value("Result", "Passed"))
            BarMark(x: .value("UTC day", day.title), y: .value("Failed", day.metrics.failed))
                .foregroundStyle(by: .value("Result", "Failed"))
            BarMark(x: .value("UTC day", day.title), y: .value("Pending", day.metrics.pending))
                .foregroundStyle(by: .value("Result", "Pending"))
            BarMark(x: .value("UTC day", day.title), y: .value("Cancelled", day.metrics.cancelled))
                .foregroundStyle(by: .value("Result", "Cancelled"))
            BarMark(x: .value("UTC day", day.title), y: .value("Skipped", day.metrics.skipped))
                .foregroundStyle(by: .value("Result", "Skipped"))
            BarMark(x: .value("UTC day", day.title), y: .value("Other", day.metrics.other))
                .foregroundStyle(by: .value("Result", "Other"))
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .frame(height: 210)
        .accessibilityLabel("Observed CI executions by UTC day")
    }
}
