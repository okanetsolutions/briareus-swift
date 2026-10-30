// The CI/CD screen's sections: the totals as tiles, the daily stacked bars (Swift Charts, in a card as the Resources
// charts are), a list of groups (repositories, failing checks) and the recent runs with Load more. They draw CILogic's
// values; words and tones are decided there.
import Charts
import SwiftUI

/// Total, success rate in its tone, failed, average duration and pending.
struct CISummaryTiles: View {
    var totals: CIMetrics
    var width: CGFloat

    var body: some View {
        StatTiles(width: width, tiles: totals.tiles(), valueTones: totals.tileTones)
    }
}

/// One bar per day, succeeded, failed and the rest stacked, with a legend.
struct CIDailyChart: View {
    var bars: [CIDailyBar]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Checks per day").font(Theme.subheadlineSemibold).foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    ForEach(CIDailyBar.Kind.allCases, id: \.self) { kind in
                        HStack(spacing: 4) {
                            Circle().fill(Theme.color(kind.tone)).frame(width: 8, height: 8)
                            Text(kind.title).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                }
                if bars.isEmpty {
                    Text("No day in this window has a check.").font(Theme.footnote).foregroundStyle(Theme.muted)
                } else {
                    chart.frame(height: 160)
                }
            }
        }
    }

    private var chart: some View {
        Chart(bars) { bar in
            BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Checks", bar.count))
                .foregroundStyle(by: .value("Result", bar.kind.title))
        }
        .chartForegroundStyleScale(domain: CIDailyBar.Kind.allCases.map(\.title),
                                   range: CIDailyBar.Kind.allCases.map { Theme.color($0.tone) })
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel().font(Theme.caption2)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(Theme.caption2)
            }
        }
        .accessibilityLabel("Checks per day")
    }
}

/// A titled list of repositories or checks: name (and a check's app), total, success rate and failures.
struct CIGroupList: View {
    var title: String
    var groups: [CIGroup]

    var body: some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(title: title)
                ForEach(groups) { CIGroupRow(group: $0) }
            }
        }
    }
}

private struct CIGroupRow: View {
    var group: CIGroup

    var body: some View {
        let m = group.metrics
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.key).font(Theme.subheadline).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                if let app = group.app { Text(app).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1) }
            }
            Spacer(minLength: 8)
            Text("\(m.total) total").font(Theme.footnote).foregroundStyle(Theme.muted).monospacedDigit()
            Text(m.successText).font(Theme.footnoteSemibold).foregroundStyle(Theme.color(m.successTone)).monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
            Text("\(m.failed) failed").font(Theme.footnote).foregroundStyle(Theme.color(m.failedTone)).monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BriareusRadius.md).fill(Theme.raise))
        .accessibilityElement(children: .combine)
    }
}

/// The recent runs in the window, newest first; a run opens on GitHub.
struct CIRunsList: View {
    @ObservedObject var model: CIStatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Recent runs")
            if let e = model.runsError {
                Notice(message: e)
                Button("Retry") { model.retryRuns() }.dashButton(.bordered).disabled(model.loading || model.loadingMore)
            }
            if model.runs.isEmpty && !model.loading && model.runsError == nil {
                EmptyNote(title: "No runs in this window.")
            }
            ForEach(model.runs) { run in
                CIRunRow(run: run) { model.open(run) }
            }
            if model.nextOffset != nil {
                Button(model.loadingMore ? "Loading\u{2026}" : "Load more") { model.loadMoreRuns() }
                    .dashButton(.bordered).disabled(model.loadingMore || model.loading).padding(.top, 6)
            }
            if model.truncated {
                Text("The server stopped listing runs before the start of this window; pick a shorter window to see the rest.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }
    }
}

private struct CIRunRow: View {
    var run: CIRun
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Circle().fill(Theme.color(run.state.tone)).frame(width: 8, height: 8)
                    .help(run.state.title).accessibilityLabel(run.state.title)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(run.name).font(Theme.subheadline).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                        if let app = run.app { Text(app).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1) }
                    }
                    Text(run.meta).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if let at = run.runAt { Text(formatRelative(at)).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BriareusRadius.md).fill(Theme.raise))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSafeWebURL(run.url))
        .handCursor(isSafeWebURL(run.url))
    }
}
