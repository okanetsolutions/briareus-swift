// A session's Resources: what it costs the machine now (CPU, memory, processes, workspace disk), each kind of process it
// runs, and its last hour of CPU and memory. Pushed over the conversation from its header; read with any token through
// `GET /sessions/{id}/stats`, again every time the server samples.
import SwiftUI

struct SessionStatsScreen: View {
    let session: Session
    /// The page's width, for how many tiles fit across.
    @State private var width: CGFloat = 0
    @StateObject private var model: SessionStatsModel

    init(session: JSON) {
        let s = Session(raw: session)
        self.session = s
        _model = StateObject(wrappedValue: SessionStatsModel(sessionID: s.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Resources", subtitle: session.displayTitle, status: session.sidebarState, buttons: [
                HeaderButton(glyph: "arrow.clockwise", tip: "Read the figures again") { Task { await model.load() } },
            ])
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
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
            EmptyNote(title: "This server does not report session resources.")
        } else if let reading = model.reading {
            if let error = model.error { NoticeBox(message: error) }
            if reading.isOpen {
                StatTiles(width: width, tiles: reading.tiles)
                if !reading.roleRows.isEmpty {
                    SectionTitle(title: "Processes")
                    ForEach(reading.roleRows) { StatsRowView(row: $0) }
                }
                SectionTitle(title: "Last hour")
                ForEach(reading.charts) { StatsChartView(chart: $0) }
            } else {
                EmptyNote(title: "The session is not open.", detail: "A closed session runs nothing; reopen it to see what it costs.")
            }
        } else if let error = model.error {
            NoticeBox(message: error)
        } else {
            LoadingNote()
        }
    }
}
