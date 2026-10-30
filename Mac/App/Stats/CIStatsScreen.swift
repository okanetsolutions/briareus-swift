// The CI/CD screen, opened from ◉ Status: what GitHub's checks did across the token's projects over a window. The filter
// bar (window, project, Checks or legacy statuses), the totals as tiles, a stacked bar per day, then the repositories, the
// checks failing most and the recent runs, which open on GitHub. The sections are in CIStatsSections.swift.
import SwiftUI

struct CIStatsScreen: View {
    @StateObject private var model = CIStatsModel()
    @ObservedObject private var store = Store.shared
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "CI/CD", subtitle: "\(model.projectTitle) \u{00B7} last \(model.filter.days) days")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Color.clear.frame(height: 0)
                    if !CIStatsModel.offered {
                        EmptyNote(title: "This server does not report CI/CD history.", detail: "Update the server to see its checks here.")
                    } else {
                        CIFilterBar(model: model)
                        content
                    }
                    Color.clear.frame(height: 4)
                }
                .padding(.horizontal, Theme.paneMargin)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fdReadWidth($width)
            }
        }
        .onAppear { if model.stats == nil { model.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.reload() }
    }

    @ViewBuilder private var content: some View {
        if let error = model.error { Notice(message: error) }
        if let stats = model.stats {
            if stats.totals.total == 0 {
                EmptyNote(title: "No checks observed in this window.",
                          detail: model.filter.repo == nil ? "Try a longer window." : "Try a longer window or All projects.")
                if model.filter.isFiltered { Button("Clear filters") { model.clearFilters() }.dashButton(.bordered) }
            } else {
                CISummaryTiles(totals: stats.totals, width: width)
                CIDailyChart(bars: ciDailyBars(stats.daily))
                CIGroupList(title: "Repositories", groups: stats.repositories)
                CIGroupList(title: "Most failing checks", groups: stats.mostFailing())
            }
            if model.runsOffered { CIRunsList(model: model) }
        } else if model.loading {
            LoadingNote(text: "Loading CI/CD history\u{2026}")
        }
    }
}

/// The window, the project, Checks or Statuses, and Reload.
private struct CIFilterBar: View {
    @ObservedObject var model: CIStatsModel

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 8) {
            Segments(titles: CIFilter.windows.map { "\($0) days" }, selected: CIFilter.windows.firstIndex(of: model.filter.days),
                     dangerFirst: false) { model.setDays(CIFilter.windows[$0]) }
            Button("\(model.projectTitle) \u{25BE}") { model.pickProject() }.dashButton(.bordered)
            Segments(titles: ["Checks", "Statuses"], selected: model.filter.statuses ? 1 : 0, dangerFirst: false) {
                model.setStatuses($0 == 1)
            }
            Button(model.loading ? "Loading\u{2026}" : "Reload") { model.reload() }.dashButton(.bordered).disabled(model.loading)
        }
        .disabled(model.loading)
    }
}
