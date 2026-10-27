// Resources of registered SSH hosts, drawn with the existing stats tiles and charts.
import SwiftUI

struct SSHResourcesScreen: View {
    @StateObject private var model = SSHResourcesModel()
    @State private var width: CGFloat = 0
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "SSH resources", subtitle: "Last 24 hours · sampled every minute", buttons: [
                HeaderButton(glyph: "arrow.clockwise", tip: "Refresh resources") { Task { await model.reload() } },
                HeaderButton(glyph: "xmark", label: "Done", tip: "Close resources") { dismiss() },
            ])
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fdReadWidth($width)
                    .padding(Theme.paneMargin)
            }
        }
        .frame(minWidth: 650, minHeight: 550)
        .task { await model.followServers() }
        .task(id: model.selectedID) { await model.followHistory() }
    }
    @ViewBuilder private var content: some View {
        if !model.available {
            EmptyNote(title: "This server does not report SSH resources.")
        } else if !model.loaded {
            LoadingNote()
        } else {
            if let error = model.error { NoticeBox(message: error) }
            if model.servers.isEmpty {
                EmptyNote(title: "No SSH server is shared with this device.")
            } else {
                Picker("Server", selection: $model.selectedID) {
                    ForEach(model.servers) { server in Text(server.title).tag(server.id) }
                }
                if let server = model.selected { Text(server.status).font(Theme.footnote).foregroundStyle(Theme.muted) }
                if let updated = model.reading?.updated { Text(updated, style: .time).font(Theme.footnote).foregroundStyle(Theme.muted) }
                if let error = model.historyError { NoticeBox(message: error) }
                SSHResourceDetails(reading: model.reading, loaded: model.historyLoaded, width: width)
            }
        }
    }
}

private struct SSHResourceDetails: View {
    var reading: SSHResourceReading?
    var loaded: Bool
    var width: CGFloat
    var body: some View {
        if let reading, !reading.samples.isEmpty {
            if let error = reading.error { NoticeBox(message: error) }
            StatTiles(width: width, tiles: reading.tiles)
            SectionTitle(title: "Disks")
            StatTiles(width: width, tiles: reading.diskTiles)
            SectionTitle(title: "Network · per interface")
            StatTiles(width: width, tiles: reading.networkTiles)
            SectionTitle(title: "Last 24 hours")
            ForEach(reading.charts) { StatsChartView(chart: $0) }
        } else if loaded {
            EmptyNote(title: "No samples in the last 24 hours. Enable monitoring in SSH settings on a Linux server with Python 3.")
        } else {
            LoadingNote()
        }
    }
}
