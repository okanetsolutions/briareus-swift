// The Server dashboard, as the Mac's: the machine Briareus runs on and the server process (CPU, memory, load, uptime), its
// disks, the open sessions together, the last hour as lines, then every open session, the busiest first; a row opens that
// session's Resources. Opened from the Findings tab's status; read with any token through `GET /stats/server` and
// `GET /stats/sessions`, again every time the server samples.
import SwiftUI

struct ServerStatsScreen: View {
    @EnvironmentObject private var store: Store
    @State private var showSSHResources = false
    @StateObject private var model = ServerStatsModel()
    @Environment(\.navigate) private var navigate

    var body: some View {
        content
            .navigationTitle("Server")
            .toolbar {
                if store.supports("ssh_resource_servers") {
                    Button("SSH resources", systemImage: "server.rack") { showSSHResources = true }
                }
            }
            .sheet(isPresented: $showSSHResources) { SSHResourcesScreen() }
        .task { await model.follow() }
            .refreshable { await model.load() }
    }

    @ViewBuilder private var content: some View {
        if !model.available {
            ContentUnavailableView("Not Reported", systemImage: "gauge.with.dots.needle.33percent",
                                   description: Text("This server does not report its resources."))
        } else if let server = model.server {
            List {
                Section {
                    if let error = model.error { ErrorNotice(message: error) }
                    StatTiles(tiles: server.tiles).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                if !server.diskTiles.isEmpty {
                    Section("Disks") { StatTiles(tiles: server.diskTiles).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                }
                Section("Last hour") { ForEach(server.charts) { StatsChartView(chart: $0) } }
                if model.listsSessions {
                    Section("Open sessions") {
                        if model.rows.isEmpty { Text("No session is open.").foregroundStyle(.secondary) }
                        ForEach(model.rows) { row in
                            Button { navigate(.sessionStats(session: model.record(row))) } label: { StatsRowView(row: row) }
                                .tint(.primary)
                        }
                    }
                }
            }
        } else if let error = model.error {
            List { ErrorNotice(message: error) }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
