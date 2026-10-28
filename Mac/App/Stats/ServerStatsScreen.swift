// The Server dashboard: the machine Briareus runs on and the server process (CPU, memory, load, uptime), its disks, the
// open sessions together, the last hour as lines, then every open session, the busiest first; a row opens that session's
// Resources. Opened from ◉ Status; read with any token through `GET /stats/server` and `GET /stats/sessions`, again every
// time the server samples.
import SwiftUI

struct ServerStatsScreen: View {
    /// The page's width, for how many tiles fit across.
    @State private var width: CGFloat = 0
    @StateObject private var model = ServerStatsModel()
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "\u{25A4} Server", subtitle: model.server.map { "\($0.host.cpus) cores \u{00B7} \($0.openSessions) open sessions" },
                       buttons: [HeaderButton(glyph: "arrow.clockwise", tip: "Read the figures again") { Task { await model.load() } }])
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if store.supports("ssh_monitoring") {
                        Button("Registered SSH servers") { Navigator.shared.push(.sshMonitoring(serverID: nil)) }.dashButton(.bordered)
                    }
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fdReadWidth($width)
                .padding(.horizontal, Theme.paneMargin).padding(.vertical, 12)
            }
        }
        .task { await model.follow() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in Task { await model.load() } }
    }

    @ViewBuilder private var content: some View {
        if !model.available {
            EmptyNote(title: "This server does not report its resources.")
        } else if let server = model.server {
            if let error = model.error { NoticeBox(message: error) }
            StatTiles(width: width, tiles: server.tiles)
            if !server.diskTiles.isEmpty {
                SectionTitle(title: "Disks")
                StatTiles(width: width, tiles: server.diskTiles)
            }
            SectionTitle(title: "Last hour")
            ForEach(server.charts) { StatsChartView(chart: $0) }
            if model.listsSessions { OpenSessionsList(rows: model.rows, open: model.open) }
        } else if let error = model.error {
            NoticeBox(message: error)
        } else {
            LoadingNote()
        }
    }
}

/// The open sessions, each a row that opens its own Resources.
private struct OpenSessionsList: View {
    var rows: [StatsRow]
    var open: (StatsRow) -> Void
    var body: some View {
        SectionTitle(title: "Open sessions")
        if rows.isEmpty {
            EmptyNote(title: "No session is open.")
        }
        ForEach(rows) { row in
            Button { open(row) } label: { StatsRowView(row: row).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("See what this session costs")
        }
    }
}
