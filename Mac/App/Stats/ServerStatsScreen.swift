// The Server dashboard stays in one pane, with only the selected resource panel mounted and polling.
import SwiftUI

struct ServerStatsScreen: View {
    @State private var width: CGFloat = 0
    @StateObject private var model: ServerStatsModel
    private let embedded: Bool
    @State private var monitoredServerID: Double?
    @ObservedObject private var store = Store.shared

    init(model: ServerStatsModel? = nil, embedded: Bool = false) {
        _model = StateObject(wrappedValue: model ?? ServerStatsModel())
        self.embedded = embedded
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                PaneHeader(title: "\u{25A4} Server", subtitle: model.server.map { "\($0.host.cpus) cores \u{00B7} \($0.openSessions) open sessions" },
                           buttons: model.tab == .sshServers ? [] : [HeaderButton(glyph: "arrow.clockwise", tip: "Refresh this tab") { Task { await model.load() } }])
                TabNav {
                    ForEach(model.tabs) { tab in
                        TabNavItem(title: tab.title, active: model.tab == tab) { model.tab = tab }
                            .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                    }
                }.padding(.horizontal, Theme.paneMargin)
            }
            if model.tabs.isEmpty {
                EmptyNote(title: "This server does not report its resources.")
            } else if model.tab == .sshServers {
                RegisteredServersTab(serverID: $monitoredServerID)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let error = model.error { NoticeBox(message: error) }
                        content
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fdReadWidth($width)
                    .padding(.horizontal, Theme.paneMargin).padding(.vertical, 12)
                }.id(model.tab)
            }
        }
        .task(id: model.tab) { await model.follow() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in Task { await model.load() } }
    }

    @ViewBuilder private var content: some View {
        if model.tab == .sessions {
            if model.sessionsLoaded {
                OpenSessionsList(rows: model.rows, open: model.open)
            } else if model.error == nil { LoadingNote() }
        } else if let server = model.server {
            switch model.tab {
            case .overview:
                SectionTitle(title: "Machine and Briareus")
                StatTiles(width: width, tiles: server.tiles)
            case .history:
                SectionTitle(title: "Last hour")
                ForEach(model.charts) { StatsChartView(chart: $0) }
            case .disks:
                SectionTitle(title: "Storage")
                if server.diskTiles.isEmpty { EmptyNote(title: "No disks are reported.") }
                StatTiles(width: width, tiles: server.diskTiles)
            case .sessions, .sshServers: EmptyView()
            }
        } else if model.error == nil { LoadingNote() }
    }
}

/// Remote hosts stay under the dashboard's tabs, including the selected host's telemetry.
private struct RegisteredServersTab: View {
    @Binding var serverID: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if serverID != nil {
                Button("All SSH servers", systemImage: "chevron.left") { serverID = nil }
                    .dashButton(.plain).padding(.horizontal, Theme.paneMargin).padding(.top, 8)
            }
            SSHMonitoringScreen(serverID: serverID, embedded: true, selectServer: { serverID = $0 })
                .id(serverID)
        }
    }
}

/// The open sessions, each a row that opens its own Resources.
private struct OpenSessionsList: View {
    var rows: [StatsRow]
    var open: (StatsRow) -> Void
    var body: some View {
        SectionTitle(title: "Open sessions")
        if rows.isEmpty { EmptyNote(title: "No session is open.") }
        ForEach(rows) { row in
            Button { open(row) } label: { StatsRowView(row: row).contentShape(Rectangle()) }
                .buttonStyle(.plain).help("See what this session costs")
        }
    }
}
