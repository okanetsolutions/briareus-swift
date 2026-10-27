// Every project's open conversations, with project identity and the same rows as an individual project's list; the
// toolbar opens the board across every project, as a project's own list opens its board.
import SwiftUI

struct AllSessionsScreen: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var model = ProjectsModel.shared
    @Environment(\.navigate) private var navigate

    var body: some View {
        List {
            if let error = model.error ?? model.sessionsError {
                Section { ErrorNotice(message: error) }.listRowBackground(Theme.row)
            }
            AllSessionsRows(list: model.allSessions, loaded: model.sessionsLoaded,
                            failed: model.sessionsError != nil || model.error != nil)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.canvas)
        .navigationTitle("All sessions").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.supports("projects") && store.supports("pulls") {
                    Button { navigate(.globalBoard) } label: { Image(systemName: "arrow.triangle.pull") }
                        .accessibilityLabel("Pull requests and issues")
                }
            }
        }
        .refreshable { _ = await reading { try await model.load() } }
        .task { await poll(every: SessionFeed.shared.live ? 60 : ProjectFeed.sessionsEvery) { await reading { try await model.load() } } }
    }
}

private struct AllSessionsRows: View {
    let list: AllSessions
    let loaded: Bool
    let failed: Bool

    var body: some View {
        let rows = list.shown
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
                ContentUnavailableView(list.emptyState.title, systemImage: "bubble.left.and.text.bubble.right")
            }
            if !loaded && !failed { ProgressView().frame(maxWidth: .infinity) }
        }.listRowBackground(Theme.row)
    }
}
