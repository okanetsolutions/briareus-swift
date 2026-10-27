// The All entry in the project sidebar, drawn as a project's own screen: `‹ All projects`, the All row opening the board
// across every project (its pull requests, issues and Review List tabs), then every open conversation with its project.
import SwiftUI

struct AllSessionsScreen: View {
    @ObservedObject private var model = ProjectsModel.shared
    @ObservedObject private var navigator = Navigator.main
    @ObservedObject private var attention = AttentionModel.shared
    @ObservedObject private var store = Store.shared
    @ObservedObject private var sessionFeed = SessionFeed.shared

    var body: some View {
        let strip = SidebarStrip(selected: navigator.selectedID, waiting: model.findingsWaiting + attention.approvals,
                                 needsYou: model.overview.needsYouCount, canStartSession: store.supports("start_session")) {
            SidebarCommon.perform($0, newSessionRepo: nil)
        }
        SidebarScreenFrame(sessions: nil, strip: strip) {
            BackRow { model.showingAllSessions = false }
            Text("All sessions").font(Theme.headline).foregroundStyle(Theme.ink).padding(8)
            // The All row opens the board across every project, as a project's row opens its board.
            if store.supports("projects") && store.supports("pulls") {
                ProjectRow(name: "All", count: model.sessionsLoaded ? model.allSessions.count : nil,
                           selected: navigator.selectedID == Screen.globalPulls.id, chevron: false, height: 35) {
                    navigator.show(.globalPulls)
                }
                Color.clear.frame(height: 4)
            }
            if let error = model.error ?? model.sessionsError { Notice(message: error).padding(.horizontal, 8) }
            AllSessionsRows(list: model.allSessions, selected: navigator.selectedID, loaded: model.sessionsLoaded,
                            failed: model.sessionsError != nil || model.error != nil)
        }
        .task(id: sessionFeed.live) { await poll(every: sessionFeed.live ? 60 : 7) { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in Task { await model.load() } }
    }
}

private struct AllSessionsRows: View {
    let list: AllSessions
    let selected: String?
    let loaded: Bool
    let failed: Bool

    var body: some View {
        let rows = list.shown
        ForEach(rows, id: \.id) { session in
            SidebarSessionRow(session: session, lit: selected == "conversation:\(session.id)",
                              selectMode: false, picked: false, projectTitle: list.projectTitle(for: session)) {
                Navigator.main.show(.conversation(id: session.id, session: session.raw))
            }
        }
        if loaded && rows.isEmpty { EmptyNote(title: list.emptyState.title) }
        if !loaded && !failed { LoadingNote() }
    }
}
