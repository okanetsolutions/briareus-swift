// A project's conversations, as plainly as a phone can draw them: one list, the pinned first and then the newest, found
// by their title and the closed ones on request, each row marked by its pull request where it has one. The toolbar opens
// the project's board and a new conversation, and its menu ▶ Run on the default branch and the project's Laravel Forge.
// Renaming, pinning, closing, reopening and deleting a conversation are on its own screen.
import SwiftUI

struct ProjectView: View {
    let repo: String
    @EnvironmentObject private var store: Store
    @ObservedObject private var feed: ProjectFeed
    @Environment(\.navigate) private var navigate
    @State private var search = ""
    @State private var showClosed = false
    /// How many conversations are drawn; Show more adds a page.
    @State private var limit = conversationPageSize
    @State private var composing = false
    @State private var error: String?

    init(repo: String) {
        self.repo = repo
        _feed = ObservedObject(wrappedValue: Store.shared.feed(repo))
    }

    /// Read, not observed: the projects model changes with every live update, and redrawing the list for each was slow.
    private var title: String { ProjectsModel.shared.project(repo)?.title ?? repo }

    var body: some View {
        List {
            if let error {
                Section { ErrorNotice(message: error) }.listRowBackground(Theme.row)
            }
            Section {
                rows
            } header: {
                HStack {
                    Text("Conversations")
                    Spacer()
                    Toggle("Show closed", isOn: $showClosed).toggleStyle(.button).buttonStyle(.borderless).controlSize(.mini)
                        .font(.caption.weight(.medium)).textCase(nil)
                }
            }
            .listRowBackground(Theme.row)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.canvas)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a conversation")
        .toolbar { toolbar }
        .sheet(isPresented: $composing) {
            NewConversationSheet(repo: repo) { started in navigate(.conversation(id: started.id, session: started.raw)) }
        }
        .refreshable { _ = await load(fresh: true) }
        .task { await poll(every: ProjectFeed.sessionsEvery) { await load() } }
    }

    /// A page of rows, Show more under it, and the empty and loading states.
    @ViewBuilder private var rows: some View {
        let shown = conversationsShown(feed.sessions, search: search, showClosed: showClosed)
        let page = conversationPage(shown, limit: limit)
        let now = Date()
        ForEach(page.rows, id: \.id) { s in
            DestinationLink(destination: .conversation(id: s.id, session: s.raw)) {
                ConversationRowLabel(row: ConversationRow(s, now: now)).equatable()
            }
        }
        if page.hidden > 0 { ShowMoreRow(hidden: page.hidden) { limit += conversationPageSize } }
        if feed.sessionsLoaded && shown.isEmpty {
            Text(search.isEmpty ? (feed.sessions.isEmpty ? "No conversations here yet." : "No open conversations.") : "No matching conversations.")
                .foregroundStyle(.secondary)
        }
        if !feed.sessionsLoaded && error == nil { ProgressView().frame(maxWidth: .infinity) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if store.supports("pulls") {
                Button { navigate(.board(repo: repo)) } label: { Image(systemName: "arrow.triangle.pull") }
                    .accessibilityLabel("Pull requests and issues")
            }
            if store.supports("start_session") {
                Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New conversation")
            }
            // ▶ Run on the default branch, and the project's Laravel Forge (an Admin token's).
            if BranchRunModel.offered || ProjectForgeModel.offered {
                Menu {
                    if BranchRunModel.offered {
                        Button("Run Default Branch", systemImage: "play.fill") { navigate(.branchRun(repo: repo)) }
                    }
                    if ProjectForgeModel.offered {
                        Button("Forge Servers and Sites", systemImage: "server.rack") { navigate(.forge(repo: repo)) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
            }
        }
    }

    private func load(fresh: Bool = false) async -> APIError? {
        let failed = await reading { try await feed.loadSessions(fresh: fresh) }
        if let failed { if let said = failure(failed) { error = said } } else { error = nil }
        return failed
    }
}
