// Resources of registered SSH hosts; the server retains the rolling 24-hour window.
import SwiftUI

struct SSHResourcesScreen: View {
    @StateObject private var model = SSHResourcesModel()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            content
                .navigationTitle("SSH resources")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .refreshable { await model.reload() }
        }
        .task { await model.followServers() }
        .task(id: model.selectedID) { await model.followHistory() }
    }
    @ViewBuilder private var content: some View {
        if !model.available {
            ContentUnavailableView("Not Reported", systemImage: "gauge.with.dots.needle.33percent")
        } else if !model.loaded {
            ProgressView()
        } else {
            List {
                if let error = model.error { ErrorNotice(message: error) }
                if model.servers.isEmpty {
                    ContentUnavailableView("No SSH Servers", systemImage: "server.rack",
                                           description: Text("No SSH server is shared with this device."))
                } else {
                    Section {
                        Picker("Server", selection: $model.selectedID) {
                            ForEach(model.servers) { server in Text(server.title).tag(server.id) }
                        }
                        if let server = model.selected { Text(server.status).font(.footnote).foregroundStyle(.secondary) }
                        if let updated = model.reading?.updated { LabeledContent("Last attempt") { Text(updated, style: .time) } }
                    }
                    if let error = model.historyError { ErrorNotice(message: error) }
                    SSHResourceDetails(reading: model.reading, loaded: model.historyLoaded)
                }
            }
        }
    }
}

private struct SSHResourceDetails: View {
    var reading: SSHResourceReading?
    var loaded: Bool
    var body: some View {
        if let reading, !reading.samples.isEmpty {
            if let error = reading.error { ErrorNotice(message: error) }
            Section("Current resources") { StatTiles(tiles: reading.tiles).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            Section("Disks") { StatTiles(tiles: reading.diskTiles).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            Section("Network · per interface") { StatTiles(tiles: reading.networkTiles).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            Section("Last 24 hours") { ForEach(reading.charts) { StatsChartView(chart: $0) } }
        } else if loaded {
            Text("No samples in the last 24 hours. Enable monitoring in SSH settings on a Linux server with Python 3.")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            ProgressView()
        }
    }
}
