// A session's Resources, as the Mac's: what it costs the machine now (CPU, memory, processes, workspace disk), each kind of
// process it runs, and its last hour of CPU and memory. Opened from the conversation's menu; read with any token through
// `GET /sessions/{id}/stats`, again every time the server samples.
import SwiftUI

struct SessionStatsScreen: View {
    let session: Session
    @StateObject private var model: SessionStatsModel

    init(session: JSON) {
        let s = Session(raw: session)
        self.session = s
        _model = StateObject(wrappedValue: SessionStatsModel(sessionID: s.id))
    }

    var body: some View {
        content
            .navigationTitle("Resources")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.follow() }
            .refreshable { await model.load() }
    }

    @ViewBuilder private var content: some View {
        if !model.available {
            ContentUnavailableView("Not Reported", systemImage: "gauge.with.dots.needle.33percent",
                                   description: Text("This server does not report session resources."))
        } else if let reading = model.reading {
            List {
                Section {
                    if let error = model.error { ErrorNotice(message: error) }
                    if reading.isOpen {
                        StatTiles(tiles: reading.tiles).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                } header: { Text(session.displayTitle) }
                if !reading.isOpen {
                    ContentUnavailableView("Not Open", systemImage: "moon.zzz",
                                           description: Text("A closed session runs nothing; reopen it to see what it costs."))
                }
                if !reading.roleRows.isEmpty {
                    Section("Processes") { ForEach(reading.roleRows) { StatsRowView(row: $0) } }
                }
                if reading.isOpen {
                    Section("Last hour") { ForEach(reading.charts) { StatsChartView(chart: $0) } }
                }
            }
        } else if let error = model.error {
            List { ErrorNotice(message: error) }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
