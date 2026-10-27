// The All entry in the project sidebar: every conversation with its project, and filters across the combined list.
import SwiftUI

struct AllSessionsScreen: View {
    @ObservedObject private var model = ProjectsModel.shared
    @ObservedObject private var navigator = Navigator.main
    @ObservedObject private var attention = AttentionModel.shared
    @ObservedObject private var store = Store.shared
    @State private var search = ""
    @State private var showClosed = true

    var body: some View {
        let strip = SidebarStrip(selected: navigator.selectedID, waiting: model.findingsWaiting + attention.approvals,
                                 needsYou: model.overview.needsYouCount, canStartSession: store.supports("start_session")) {
            SidebarCommon.perform($0, newSessionRepo: nil)
        }
        SidebarScreenFrame(sessions: nil, strip: strip) {
            BackRow { model.showingAllSessions = false }
            filters
            if let error = model.sessionsError ?? model.error { Notice(message: error).padding(8) }
            AllSessionsRows(list: model.allSessions, search: search, showClosed: showClosed,
                            selected: navigator.selectedID, loaded: model.sessionsLoaded,
                            failed: model.sessionsError != nil || model.error != nil)
        }
        .task { await poll(every: SessionFeed.shared.live ? 60 : 7) { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in Task { await model.load() } }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All sessions").font(Theme.headline).foregroundStyle(Theme.ink)
            TextField("Find a session or project", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Find a session or project")
            Toggle("Show closed", isOn: $showClosed).font(Theme.caption).toggleStyle(.checkbox)
        }.padding(8)
    }
}

private struct AllSessionsRows: View {
    let list: AllSessions
    let search: String
    let showClosed: Bool
    let selected: String?
    let loaded: Bool
    let failed: Bool

    var body: some View {
        let rows = list.shown(search: search, showClosed: showClosed)
        ForEach(rows, id: \.id) { session in
            SidebarSessionRow(session: session, lit: selected == "conversation:\(session.id)",
                              selectMode: false, picked: false, projectTitle: list.projectTitle(for: session)) {
                Navigator.main.show(.conversation(id: session.id, session: session.raw))
            }
        }
        if loaded && rows.isEmpty {
            EmptyNote(title: list.emptyState.title)
        }
        if !loaded && !failed { LoadingNote() }
    }
}
