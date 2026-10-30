// The CI/CD dashboard's lists: the runs per day as stacked bars, the repositories and checks with their figures, and
// the runs a page at a time, each opening its page on GitHub. They draw CILogic's values; the tones are decided there.
import Charts
import SwiftUI

/// One bar per day, passed, failed and the rest stacked; touching a bar names its figures above the chart.
struct CIDailyChart: View {
    let days: [CIGroup]
    @State private var selected: Date?

    var body: some View {
        let dated = days.compactMap { d in ciDayDate(d.key).map { (date: $0, metrics: d.metrics) } }
        let bars = ciDailyBars(days)
        let picked = selected.flatMap { s in dated.first { Calendar.current.isDate($0.date, inSameDayAs: s) } }
        VStack(alignment: .leading, spacing: 8) {
            Text(picked.map { tip($0.date, $0.metrics) } ?? "Touch a bar for its figures")
                .font(.caption).foregroundStyle(picked == nil ? .secondary : .primary).lineLimit(1)
            Chart(bars) { s in
                BarMark(x: .value("Day", s.day, unit: .day), y: .value("Runs", s.count))
                    .foregroundStyle(Theme.color(s.kind.tone).opacity(picked == nil || picked?.date == s.day ? 1 : 0.35))
            }
            .chartXSelection(value: $selected)
            .chartXAxis {
                AxisMarks(values: stride(from: 0, to: dated.count, by: max(1, (dated.count + 5) / 6)).map { dated[$0].date }) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 160)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Runs per day")
        .accessibilityValue(dated.map { tip($0.date, $0.metrics) }.joined(separator: ", "))
    }

    private func tip(_ date: Date, _ m: CIMetrics) -> String {
        "\(date.formatted(.dateTime.month(.abbreviated).day())): \(m.total) runs, \(m.succeeded) passed, \(m.failed) failed"
    }
}

/// Repositories or checks: each name with its runs, failures and success rate.
struct CIGroupsSection: View {
    let title: String
    let groups: [CIGroup]

    var body: some View {
        if !groups.isEmpty {
            Section(title) {
                ForEach(groups) { g in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.key).font(.subheadline).lineLimit(2)
                            Text(detail(g)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(g.metrics.successText).font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.color(g.metrics.successTone))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .listRowBackground(Theme.row)
        }
    }

    private func detail(_ g: CIGroup) -> String {
        [g.app, "\(g.metrics.total) runs", g.metrics.failed > 0 ? "\(g.metrics.failed) failed" : nil, g.metrics.avgDurationText]
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

/// The window's runs, newest first; more are read on request.
struct CIRunsSection: View {
    @ObservedObject var model: CIStatsModel

    var body: some View {
        Section {
            if let error = model.runsError {
                ErrorNotice(message: error)
                Button("Retry") { Task { await model.retryRuns() } }.disabled(model.loading || model.loadingMore)
            }
            ForEach(model.runs) { CIRunRow(run: $0) }
            if model.runs.isEmpty && model.runsError == nil && !model.loading {
                Text("No runs in this window.").foregroundStyle(.secondary)
            }
            if model.nextOffset != nil {
                Button { Task { await model.loadMoreRuns() } } label: {
                    HStack {
                        Text("Load more")
                        if model.loadingMore { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.loadingMore)
            }
        } header: {
            Text("Recent runs")
        } footer: {
            if model.truncated { Text("The server lists only the most recent runs of this window.") }
        }
        .listRowBackground(Theme.row)
    }
}

/// A run: its state dot, name, app, where it ran and when; a tap opens it on GitHub.
private struct CIRunRow: View {
    let run: CIRun

    var body: some View {
        Button { boardOpenWeb(run.url) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(Theme.color(run.state.tone)).frame(width: 8, height: 8)
                    .accessibilityLabel(run.state.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text([run.name, run.app].compactMap { $0 }.joined(separator: " \u{00B7} "))
                        .font(.subheadline).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                    if !run.meta.isEmpty { Text(run.meta).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if let at = run.runAt { Text(formatRelative(at)).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!safeWebURL(run.url))
        .accessibilityElement(children: .combine)
        .accessibilityHint(safeWebURL(run.url) ? "Opens the run on GitHub" : "")
    }
}
