// Every project's conversations, with project identity, search and the same rows as an individual project's list.
import SwiftUI

struct AllSessionsScreen: View {
    @ObservedObject private var model = ProjectsModel.shared
    @State private var search = ""
    @State private var showClosed = true

    var body: some View {
        List {
            if let error = model.sessionsError ?? model.error {
                Section { ErrorNotice(message: error) }.listRowBackground(Theme.row)
            }
            Section {
                Toggle("Show closed", isOn: $showClosed)
            }.listRowBackground(Theme.row)
            AllSessionsRows(list: model.allSessions, search: search, showClosed: showClosed,
                            loaded: model.sessionsLoaded, failed: model.sessionsError != nil || model.error != nil)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.canvas)
        .navigationTitle("All sessions").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a session or project")
        .refreshable { _ = await reading { try await model.load() } }
        .task { await poll(every: ProjectFeed.sessionsEvery) { await reading { try await model.load() } } }
    }
}

private struct AllSessionsRows: View {
    let list: AllSessions
    let search: String
    let showClosed: Bool
    let loaded: Bool
    let failed: Bool

    var body: some View {
        let rows = list.shown(search: search, showClosed: showClosed)
        Section {
            ForEach(rows, id: \.id) { session in
                DestinationLink(destination: .conversation(id: session.id, session: session.raw)) {
                    VStack(alignment: .leading, spacing: 4) {
                        ConversationRowLabel(session: session)
                        Text(list.projectTitle(for: session)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if loaded && rows.isEmpty {
                ContentUnavailableView(list.count == 0 ? "No sessions yet" : "No matching sessions",
                                       systemImage: "bubble.left.and.text.bubble.right")
            }
            if !loaded && !failed { ProgressView().frame(maxWidth: .infinity) }
        }.listRowBackground(Theme.row)
    }
}
