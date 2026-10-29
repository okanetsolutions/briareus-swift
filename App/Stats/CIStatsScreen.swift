// The CI/CD dashboard, as the Mac's CI stats: the window and filters, the summary figures, the runs per day, the
// repositories and the checks failing most, then the runs themselves a page at a time. Opened from the Status tab; read
// through `GET /stats/ci` and `GET /ci/runs` by CIStatsModel. The sections are in CIStatsSections.swift.
import SwiftUI

struct CIStatsScreen: View {
    @StateObject private var model = CIStatsModel()
    @ObservedObject private var projects = ProjectsModel.shared

    var body: some View {
        List {
            CIFilterSection(filter: $model.filter, projects: projects.projects)
            content
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.canvas)
        .navigationTitle("CI/CD")
        .task { await model.reload() }
        .refreshable { await model.reload() }
    }

    @ViewBuilder private var content: some View {
        if let error = model.error {
            Section { ErrorNotice(message: error) }.listRowBackground(Theme.row)
        }
        if let stats = model.stats {
            if stats.totals.total == 0 {
                ContentUnavailableView("No runs observed", systemImage: "checkmark.seal",
                                       description: Text("Nothing ran in this window for these filters."))
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else {
                CISummarySection(totals: stats.totals)
                if !stats.daily.isEmpty { Section("Runs per day") { CIDailyChart(days: stats.daily) }.listRowBackground(Theme.row) }
                CIGroupsSection(title: "Repositories", groups: stats.repositories)
                CIGroupsSection(title: "Most failing checks", groups: stats.mostFailing())
                CIRunsSection(model: model)
            }
        } else if model.loading {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12).listRowBackground(Color.clear)
        }
    }
}

/// The window, the project and whether checks or legacy commit statuses are counted.
private struct CIFilterSection: View {
    @Binding var filter: CIFilter
    let projects: [Project]

    var body: some View {
        Section {
            Picker("Window", selection: $filter.days) {
                ForEach(CIFilter.windows, id: \.self) { Text("\($0) days").tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Project", selection: $filter.repo) {
                Text("All projects").tag(String?.none)
                ForEach(projects, id: \.repo) { Text($0.title).tag(Optional($0.repo)) }
            }
            Picker("Source", selection: $filter.statuses) {
                Text("Checks").tag(false)
                Text("Statuses").tag(true)
            }
            .pickerStyle(.segmented)
        }
        .listRowBackground(Theme.row)
    }
}

/// The window's figures as tiles, two across; the success rate in its tone.
private struct CISummarySection: View {
    let totals: CIMetrics

    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                CIFigureTile(label: "Total", value: "\(totals.total)")
                CIFigureTile(label: "Success rate", value: totals.successText, color: Theme.color(totals.successTone))
                CIFigureTile(label: "Failed", value: "\(totals.failed)", color: totals.failed > 0 ? Theme.danger : nil)
                CIFigureTile(label: "Avg duration", value: totals.avgDurationText)
                CIFigureTile(label: "Pending", value: "\(totals.pending)")
            }
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
        }
    }
}

/// A figure over its label, as the dashboards' stat tiles draw it, its figure in `color` when given.
private struct CIFigureTile: View {
    let label: String
    let value: String
    var color: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(color ?? .primary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.raise, in: RoundedRectangle(cornerRadius: BriareusRadius.xxl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BriareusRadius.xxl, style: .continuous).stroke(Theme.line, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
