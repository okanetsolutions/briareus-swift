// The Server dashboard: focused tabs on the existing page, loading only the visible panel.
import SwiftUI

struct ServerStatsScreen: View {
    @StateObject private var model: ServerStatsModel
    private let embedded: Bool
    @State private var monitoredServerID: Double?
    @EnvironmentObject private var store: Store
    @Environment(\.navigate) private var navigate

    init(model: ServerStatsModel? = nil, embedded: Bool = false) {
        _model = StateObject(wrappedValue: model ?? ServerStatsModel())
        self.embedded = embedded
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded { DashboardTabStrip(tabs: model.tabs, selection: $model.tab, title: { $0.title }) }
            if model.tabs.isEmpty {
                ContentUnavailableView("Not Reported", systemImage: "gauge.with.dots.needle.33percent",
                                       description: Text("This server does not report its resources."))
            } else if model.tab == .sshServers {
                RegisteredServersTab(serverID: $monitoredServerID)
            } else {
                List {
                    if let error = model.error { ErrorNotice(message: error) }
                    content
                }
                .id(model.tab)
                .refreshable { await model.load() }
            }
        }
        .navigationTitle(embedded ? "Usage" : "Server")
        .task(id: model.tab) { await model.follow() }
    }

    @ViewBuilder private var content: some View {
        if model.tab == .sessions {
            if model.sessionsLoaded {
                Section("Open sessions") {
                    if model.rows.isEmpty { Text("No session is open.").foregroundStyle(.secondary) }
                    ForEach(model.rows) { row in
                        Button { navigate(.sessionStats(session: model.record(row))) } label: { StatsRowView(row: row) }
                            .tint(.primary)
                    }
                }
            } else if model.error == nil { ProgressView() }
        } else if let server = model.server {
            switch model.tab {
            case .overview:
                Section("Machine and Briareus") {
                    StatTiles(tiles: server.tiles).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            case .history:
                Section("Last hour") { ForEach(model.charts) { StatsChartView(chart: $0) } }
            case .disks:
                Section("Storage") {
                    if server.diskTiles.isEmpty { Text("No disks are reported.").foregroundStyle(.secondary) }
                    StatTiles(tiles: server.diskTiles).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            case .sessions, .sshServers: EmptyView()
            }
        } else if model.error == nil { ProgressView() }
    }
}

/// Selecting a remote host keeps its telemetry on the Server page.
private struct RegisteredServersTab: View {
    @Binding var serverID: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if serverID != nil {
                Button("All SSH servers", systemImage: "chevron.left") { serverID = nil }
                    .padding(.horizontal).padding(.vertical, 8)
            }
            SSHMonitoringScreen(serverID: serverID, embedded: true, selectServer: { serverID = $0 })
                .id(serverID)
        }
    }
}
