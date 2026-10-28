// The Server dashboard: focused tabs on the existing page, loading only the visible panel.
import SwiftUI

struct ServerStatsScreen: View {
    @StateObject private var model = ServerStatsModel()
    @State private var monitoredServerID: Double?
    @EnvironmentObject private var store: Store
    @Environment(\.navigate) private var navigate

    var body: some View {
        VStack(spacing: 0) {
            ServerDashboardTabs(tabs: model.tabs, selection: $model.tab)
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
        .navigationTitle("Server")
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

/// Scrollable system buttons keep every tab readable at large text sizes and on narrow phones.
private struct ServerDashboardTabs: View {
    var tabs: [ServerDashboardTab]
    @Binding var selection: ServerDashboardTab
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(tabs) { tab in
                        Button { selection = tab } label: {
                            Text(tab.title).font(.subheadline.weight(selection == tab ? .semibold : .regular))
                                .padding(.horizontal, 12).frame(minHeight: 44)
                                .background(selection == tab ? Theme.accent.opacity(0.12) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selection == tab ? Theme.accent : Theme.muted)
                        .accessibilityAddTraits(selection == tab ? .isSelected : [])
                        .id(tab)
                    }
                }.padding(.horizontal).padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection) { _, tab in proxy.scrollTo(tab, anchor: .center) }
        }
        .background(.bar)
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
