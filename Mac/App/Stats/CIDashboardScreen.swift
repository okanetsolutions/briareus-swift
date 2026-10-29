// CI/CD totals, trends and paged execution history on Mac.
import SwiftUI
import Charts

struct CIDashboardScreen: View {
    @StateObject private var model = CIDashboardModel()
    @ObservedObject private var projects = ProjectsModel.shared
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                filters
                Text("Observed GitHub checks only; earlier history may be incomplete. Daily totals use UTC. Durations are execution time, not billed minutes.")
                    .font(Theme.footnote).foregroundStyle(Theme.muted)
                if let error = model.error { Notice(message: error) }
                if let reading = model.reading {
                    StatTiles(width: width, tiles: reading.totals.tiles)
                    if reading.totals.total == 0 {
                        EmptyNote(title: "No observed checks", detail: "Try another project, source or window.")
                    } else {
                        SectionTitle(title: "Daily executions · UTC")
                        CIDailyChart(days: reading.daily)
                        CIGroupSection(title: "Projects", groups: reading.repositories)
                        CIGroupSection(title: "Checks", groups: reading.checks)
                    }
                }
                if model.loading { LoadingNote(text: "Loading CI/CD…") }
                if model.hasHistory { history }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fdReadWidth($width)
            .padding(Theme.paneMargin)
        }
        .task(id: model.query) { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in Task { await model.load() } }
    }

    private var filters: some View {
        HStack {
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
            Button("Refresh") { Task { await model.load() } }.dashButton(.bordered).disabled(model.loading)
        }.font(Theme.body)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Execution history")
            if let error = model.historyError { Notice(message: error) }
            ForEach(model.history.runs) { run in CIRunRow(run: run) }
            if !model.loading && model.history.runs.isEmpty && model.historyError == nil {
                EmptyNote(title: "No executions in this window.")
            }
            if model.history.nextOffset != nil {
                Button(model.loadingMore ? "Loading…" : "Load more") { Task { await model.more() } }
                    .dashButton(.bordered).disabled(model.loading || model.loadingMore)
            }
            if model.history.truncated {
                Text("More executions exist; narrow the window or select a project.").font(Theme.footnote).foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct CIGroupSection: View {
    let title: String
    let groups: [CIGroup]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: title)
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title).font(Theme.body)
                    Text(group.metrics.summary).font(Theme.caption).foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

private struct CIRunRow: View {
    let run: CIRun
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = run.url { Link(run.name, destination: url).font(Theme.body) } else { Text(run.name).font(Theme.body) }
            Text(run.detail).font(Theme.caption).foregroundStyle(Theme.muted)
            HStack {
                Text(run.result).foregroundStyle(Theme.color(run.tone))
                Text(run.duration)
                if let at = run.at { Text(at, style: .date) }
            }.font(Theme.caption)
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
