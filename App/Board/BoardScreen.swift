// A project's board on a phone (the Mac's BoardScreen): open pull requests and issues behind a segmented control, then
// the Review List; the GitHub Projects board stays on the Mac. The author, reviewer (pull requests),
// assignee (issues, No assignee among them) and label pickers in the toolbar's filter menu, kept per repository. Each pull
// request row names the errand its state asks for and offers the errands in its context menu, and its linked issues end
// with their project Status, and a swipe to its right merges it, once confirmed with what stands in the way. The Mac's
// SSH and SFTP tabs are left out: they drive local ssh and sftp processes a phone does not have.
import SwiftUI

struct BoardScreen: View {
    let repo: String
    private typealias Tab = GlobalBoardTab

    @EnvironmentObject private var store: Store
    @ObservedObject private var feed: ProjectFeed
    @ObservedObject private var catalog = ErrandCatalog.shared
    @StateObject private var filters: BoardFilters
    @StateObject private var pullActions: BoardPullActionsModel
    @StateObject private var issueStatus: IssueStatusReader
    @State private var tab = Tab.pulls
    /// The epics whose sub-issues the Issues tab hides, by number.
    @State private var foldedEpics: Set<Int> = []
    @State private var error: String?
    /// A count that redraws the Review List once a login is saved.
    @State private var loginRevision = 0

    init(repo: String) {
        self.repo = repo
        feed = Store.shared.feed(repo)
        _filters = StateObject(wrappedValue: BoardFilters(repo: repo))
        _pullActions = StateObject(wrappedValue: BoardPullActionsModel(repo: repo))
        _issueStatus = StateObject(wrappedValue: IssueStatusReader(repo: repo))
    }

    private var board: JSON { feed.board }
    private var pulls: [PullSummary] { feed.pulls }
    private var issues: [(summary: IssueSummary, raw: JSON)] { feed.issues }
    private var loaded: Bool { feed.boardLoaded || error != nil }
    private var filter: Binding<BoardFilter> { tab == .pulls ? $filters.pulls : $filters.issues }
    /// Whose review the Review List waits on: the saved GitHub login, else the project's author.
    private var reviewer: String? { _ = loginRevision; return GitHubLogin.current ?? board["author"].nonEmpty }

    var body: some View {
        let pulls = self.pulls, issues = self.issues
        let rows = tab == .pulls ? pulls.map(BoardRow.init) : issues.map { BoardRow($0.summary) }
        let review = reviewList(pulls, stacks: board["stacks"], me: reviewer)
        List {
            if let error { Section { ErrorNotice(message: error) }.listRowBackground(Theme.row) }
            BoardPullNotices(model: pullActions)
            Picker("Show", selection: $tab) {
                Text("PRs (\(pulls.count))").tag(Tab.pulls)
                Text("Issues (\(issues.count))").tag(Tab.issues)
                // Review List, the pull requests waiting on the user's review.
                Text("Review List (\(review.count))").tag(Tab.review)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            if tab == .review {
                ReviewLoginButton { loginRevision += 1 }.listRowBackground(Color.clear)
            } else if filter.wrappedValue.isOn {
                HStack {
                    Text("Showing \(rows.filter { filter.wrappedValue.passes($0) }.count) of \(rows.count)").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear filters") { filter.wrappedValue = BoardFilter(); filters.picked() }.font(.footnote).buttonStyle(.borderless)
                }
                .listRowBackground(Color.clear)
            }
            if boardShowsLoading(loaded: loaded, refreshing: feed.boardRefreshing) {
                ProgressView(tab.loadingText).frame(maxWidth: .infinity).padding(.vertical, 24).listRowBackground(Color.clear)
            }
            if tab == .pulls || tab == .review { pullRows(pulls, review: tab == .review ? review : nil) }
            else if tab == .issues { issueRows(issues) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.canvas)
        // Read, not observed: the projects model changes with every live update, and each redrew the whole board.
        .navigationTitle(ProjectsModel.shared.project(repo)?.title ?? "Board").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if feed.boardReading {
                    ProgressView().accessibilityLabel(tab.loadingText)
                }
                if tab != .review {
                    BoardFilterMenu(filter: filter, rows: rows, kinds: tab.filterKinds,
                                    stacked: tab == .pulls) { filters.picked() }
                        .disabled(!loaded || rows.isEmpty && !filter.wrappedValue.isOn)
                }
            }
        }
        .refreshable {
            // Pulling down is how an uncertain start is checked: its conversation shows on its pull request if it began.
            pullActions.checked()
            issueStatus.reset()
            async let sessions: Void? = store.supports("sessions") ? try? feed.loadSessions(fresh: true) : nil
            await read(fresh: true)
            _ = await sessions
        }
        .task {
            filters.opened(board, answered: false)
            await catalog.load()
        }
        .task { await poll(every: ProjectFeed.boardEvery) { await reading { try await load() } } }
        .task(id: tab) { if tab == .pulls || tab == .review { await read(ifStale: true) } }
        // Each linked issue's Status, one read at a time while the board is on show, the rows the filters show first.
        .onAppear { issueStatus.shown = true; issueStatus.next(pulls: self.pulls, filter: filters.pulls) }
        .onDisappear { issueStatus.shown = false }
        // Conversations start and finish faster than the board changes, and reading them asks GitHub nothing.
        .task {
            guard store.supports("sessions") else { return }
            await poll(every: ProjectFeed.sessionsEvery) { await reading { try await feed.loadSessions() } }
        }
        .onChange(of: issues.isEmpty) { _, empty in if empty && tab == .issues && !board["issuesError"].isSet && feed.boardLoaded { self.tab = .pulls } }
        .boardPullPrompts(pullActions, reload: { await read(fresh: true) })
    }

    private func load(fresh: Bool = false, ifStale: Bool = false) async throws {
        do {
            if fresh { try await feed.refreshBoard() }
            else if ifStale { guard try await feed.refreshBoardIfStale() else { return } }
            else { try await feed.loadBoard(fresh: fresh) }
            filters.opened(board, answered: true)
            error = nil
            issueStatus.next(pulls: pulls, filter: filters.pulls)
        } catch {
            if let said = failure(error) { self.error = said }
            throw error
        }
    }
    private func read(fresh: Bool = false, ifStale: Bool = false) async {
        _ = await reading { try await load(fresh: fresh, ifStale: ifStale) }
    }

    // MARK: Pull requests

    /// The pull requests the filters show, or the Review List's when given: labelled requires-dev-review, not the
    /// user's, and not stacked on another, or labelled feedback-implemented on one they review.
    @ViewBuilder private func pullRows(_ pulls: [PullSummary], review reviewRows: [PullSummary]? = nil) -> some View {
        let review = reviewRows != nil
        let shown = reviewRows ?? pulls.filter { filters.pulls.passes(BoardRow($0)) }
        Section {
            ForEach(shown, id: \.number) { pull in
                let stack = StackPosition(pull.raw["stack"], stacks: board["stacks"])
                BoardPullListRow(model: pullActions, pull: pull, stack: stack, issueStatus: issueStatus.statuses(pull))
            }
        } footer: {
            if let at = boardDateParse(board["syncedAt"].string), !shown.isEmpty { Text("Synced with GitHub \(formatRelative(at)).") }
        }
        if !boardShowsLoading(loaded: loaded, refreshing: feed.boardRefreshing) && shown.isEmpty && error == nil {
            ContentUnavailableView(review ? (reviewer == nil ? "Set your GitHub login" : "Nothing waiting on your review")
                                   : pulls.isEmpty ? "No open pull requests" : "No pull requests match the filters", systemImage: "arrow.triangle.pull")
                .listRowBackground(Color.clear)
        }
    }

    // MARK: Issues

    @ViewBuilder private func issueRows(_ issues: [(summary: IssueSummary, raw: JSON)]) -> some View {
        if let refused = board["issuesError"].string {
            Section {
                Text("GitHub would not read this repository’s issues with the server’s token. A fine-grained token needs Issues: read. The pull requests are unaffected.")
                    .font(.footnote).foregroundStyle(.secondary)
                ErrorNotice(message: refused)
            }
            .listRowBackground(Theme.row)
        } else {
            let visible = issues.filter { filters.issues.passes(BoardRow($0.summary)) }
            let summaries = visible.map(\.summary)
            let nested = issuesFolded(issuesNested(summaries, repo: repo), summaries, folded: foldedEpics)
            Section {
                ForEach(nested, id: \.index) { row in
                    let item = visible[row.index]
                    let number = item.summary.number
                    DestinationLink(destination: .issue(repo: repo, issue: item.raw)) {
                        BoardIssueRow(issue: item.summary, repo: repo, nested: row.depth > 0,
                                      folded: row.children > 0 ? foldedEpics.contains(number) : nil,
                                      fold: { withAnimation { if foldedEpics.remove(number) == nil { foldedEpics.insert(number) } } })
                            .padding(.leading, CGFloat(min(row.depth, 4)) * 14)
                    }
                    .contextMenu {
                        if safeWebURL(item.summary.url) {
                            Button { boardOpenWeb(item.summary.url) } label: { Label("Open on GitHub", systemImage: "safari") }
                            Button { Pasteboard.copy(item.summary.url ?? "") } label: { Label("Copy link", systemImage: "link") }
                        }
                    }
                }
            } footer: {
                if board["issuesTruncated"].is(true) { Text("This repository has more open issues; only the most recently updated are listed.") }
            }
            if !boardShowsLoading(loaded: loaded, refreshing: feed.boardRefreshing) && visible.isEmpty && error == nil {
                ContentUnavailableView(issues.isEmpty ? "No open issues" : "No issues match the filters", systemImage: "smallcircle.filled.circle")
                    .listRowBackground(Color.clear)
            }
        }
    }
}
