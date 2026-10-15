// The Resources screens' pieces, as the Mac's StatsKit draws them in system text styles: a chart of the last hour and a
// row of figures. They draw StatsLogic's values; the tone of a gauge and the slot of a line are decided there.
import Charts
import SwiftUI

/// The last hour as lines on one axis, with a legend naming each line and its latest value.
struct StatsChartView: View {
    var chart: StatsChart
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(chart.title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                ForEach(chart.series) { s in
                    HStack(spacing: 4) {
                        Circle().fill(Theme.series(s.slot)).frame(width: 8, height: 8)
                        Text("\(s.label) \(s.latest)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if chart.plots {
                StatsLines(chart: chart).frame(height: 140)
            } else {
                Text("The history fills in as the server samples.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct StatsLines: View {
    var chart: StatsChart
    var body: some View {
        let unit = chart.series.first ?? StatsSeries(id: "", label: "", unit: .percent, points: [], slot: 0)
        Chart {
            ForEach(chart.series) { s in
                ForEach(s.points, id: \.at) { p in
                    LineMark(x: .value("Time", p.at), y: .value(s.label, p.value), series: .value("Series", s.label))
                        .foregroundStyle(Theme.series(s.slot))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(unit.axis(d)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chart.title)
        .accessibilityValue(chart.series.map { "\($0.label) \($0.latest)" }.joined(separator: ", "))
    }
}

/// A session or a kind of process: its name and line, then CPU with its share of the machine as a bar, and memory.
struct StatsRowView: View {
    var row: StatsRow
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.body).lineLimit(1).truncationMode(.tail)
                Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(row.cpu).font(.subheadline.weight(.semibold).monospacedDigit())
                StatGauge(fraction: row.cpuShare ?? 0, color: Theme.color(statsTone(row.cpuShare))).frame(width: 56)
            }
            Text(row.memory).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
