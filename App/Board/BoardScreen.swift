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
    @ObservedObject private var projects = ProjectsModel.shared
    @StateObject private var filters: BoardFilters
    @StateObject private var errands: ErrandRunner
    @StateObject private var issueStatus: IssueStatusReader
    @State private var tab = Tab.pulls
    /// The epics whose sub-issues the Issues tab hides, by number.
    @State private var foldedEpics: Set<Int> = []
    @State private var error: String?
    /// The pull request whose Merge waits for a yes, the one being merged from its row, and what the last merge left to say.
    @State private var mergeAsked: PullSummary?
    @State private var mergingNumber = 0
    @State private var mergeNote: String?
    /// A count that redraws the Review List once a login is saved.
    @State private var loginRevision = 0

    init(repo: String) {
        self.repo = repo
        feed = Store.shared.feed(repo)
        _filters = StateObject(wrappedValue: BoardFilters(repo: repo))
        _errands = StateObject(wrappedValue: ErrandRunner(repo: repo))
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
        List {
            if let error { Section { ErrorNotice(message: error) }.listRowBackground(Theme.row) }
            ErrandNotice(runner: errands, place: "in the project")
            if let note = mergeNote { Section { ErrorNotice(message: note) }.listRowBackground(Theme.row) }
            Picker("Show", selection: $tab) {
                Text("PRs (\(pulls.count))").tag(Tab.pulls)
                Text("Issues (\(issues.count))").tag(Tab.issues)
                // Review List, the pull requests waiting on the user's review.
                Text("Review List (\(reviewList(pulls, stacks: board["stacks"], me: reviewer).count))").tag(Tab.review)
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
            if tab == .pulls || tab == .review { pullRows(pulls, review: tab == .review) } else if tab == .issues { issueRows(issues) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.canvas)
        .navigationTitle(projects.project(repo)?.title ?? "Board").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if feed.boardReading {
                    ProgressView().accessibilityLabel(tab.loadingText)
                }
                if tab != .review {
                    BoardFilterMenu(filter: filter, rows: rows, kinds: tab == .pulls ? [.author, .reviewer, .label] : [.author, .assignee, .label],
                                    stacked: tab == .pulls) { filters.picked() }
                        .disabled(!loaded || rows.isEmpty && !filter.wrappedValue.isOn)
                }
            }
        }
        .refreshable {
            // Pulling down is how an uncertain start is checked: its conversation shows on its pull request if it began.
            errands.checked()
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
        .errandPrompts(errands)
        .alert(mergeAsked.map { "Merge #\($0.number)?" } ?? "",
               isPresented: Binding(get: { mergeAsked != nil }, set: { if !$0 { mergeAsked = nil } }), presenting: mergeAsked) { pull in
            Button("Merge") { merge(pull) }
            Button("Cancel", role: .cancel) {}
        } message: { pull in
            Text(mergeQuestion(pull))
        }
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

    /// The pull requests the filters show, or for `review` the Review List's: labelled requires-dev-review, not the
    /// user's, and not stacked on another, or labelled feedback-implemented on one they review.
    @ViewBuilder private func pullRows(_ pulls: [PullSummary], review: Bool = false) -> some View {
        let shown = review ? reviewList(pulls, stacks: board["stacks"], me: reviewer) : pulls.filter { filters.pulls.passes(BoardRow($0)) }
        Section {
            ForEach(shown, id: \.number) { pull in
                let stack = StackPosition(pull.raw["stack"], stacks: board["stacks"])
                let actions = pull.branch.isEmpty ? [] : boardErrands(catalog: catalog.catalog, pull: pull, failedChecks: 0)
                DestinationLink(destination: .pull(repo: repo, number: pull.number, stack: stack?.json, summary: pull.raw)) {
                    BoardPullRow(pull: pull, stack: stack, repo: repo, activeRuns: activeRuns(pull.number),
                                 suggested: actions.first { $0.isSuggested(for: pull) }?.label, issueStatus: issueStatus.statuses(pull))
                }
                .contextMenu { rowMenu(pull, actions: actions) }
                .swipeActions(edge: .trailing) {
                    if mergeOffered(pull) {
                        Button { mergeAsked = pull } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
                            .tint(Theme.accent).disabled(mergingNumber != 0)
                    }
                }
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

    /// The row's errands as the Mac's row buttons offer them, less ▶ Run, which is the pull request's own Run tab.
    @ViewBuilder private func rowMenu(_ pull: PullSummary, actions: [BoardAction]) -> some View {
        let errandList = actions.filter { $0.id != "run" }
        if !errandList.isEmpty {
            Section("Errands") {
                ForEach(errandList, id: \.id) { a in
                    Button(role: a.isDestructive ? .destructive : nil) {
                        errands.ask(a, number: pull.number, branch: pull.branch)
                    } label: {
                        Label(a.isSuggested(for: pull) ? "\(a.label) (suggested)" : a.label, systemImage: a.isSuggested(for: pull) ? "sparkles" : errandSymbol(a.id))
                    }
                    .disabled(errands.busy || errands.uncertain)
                }
            }
        }
        if mergeOffered(pull) {
            Button { mergeAsked = pull } label: { Label(mergingNumber == pull.number ? "Merging…" : "Merge…", systemImage: "arrow.triangle.merge") }
                .disabled(mergingNumber != 0)
        }
        if safeWebURL(pull.url) {
            Button { boardOpenWeb(pull.url) } label: { Label("Open on GitHub", systemImage: "safari") }
            Button { Pasteboard.copy(pull.url ?? "") } label: { Label("Copy link", systemImage: "link") }
        }
        if !pull.branch.isEmpty {
            Button { Pasteboard.copy(pull.branch) } label: { Label("Copy branch name", systemImage: "arrow.triangle.branch") }
        }
    }

    // MARK: Merge

    /// Merge is offered on every pull request that is not a draft, to a token that may write on a server that reads and
    /// merges one.
    private func mergeOffered(_ pull: PullSummary) -> Bool {
        !pull.draft && store.canManage && store.supports("pull") && store.supports("merge_pull")
    }
    /// What the row says stands in the way: its conflicts, and checks failing or still running.
    private func mergeQuestion(_ pull: PullSummary) -> String {
        var message = "\u{201C}\(pull.title)\u{201D} is squash-merged into \(pull.baseBranch.isEmpty ? "its base branch" : pull.baseBranch) on GitHub."
        if pull.conflicting { message += "\n\nThis branch has conflicts that must be resolved before it can merge." }
        if pull.checksFailed { message += "\n\nSome checks failed." }
        else if pull.checks == "pending" || pull.checks == "expected" { message += "\n\nSome checks are still running." }
        return message
    }
    /// The row carries no head commit, and the server merges only the head that was read, so the pull request is read
    /// first and squash-merged at the head that read returns. Then the list is read again.
    private func merge(_ pull: PullSummary) {
        guard mergingNumber == 0 else { return }
        let number = pull.number
        mergingNumber = number; mergeNote = nil
        Task {
            defer { mergingNumber = 0 }
            let pr: JSON
            do { pr = try await store.call("pull", ["repo": .string(repo), "pr": JSON(number)])["pr"] }
            catch { mergeNote = failure(error); return }
            guard pr["state"].string == "open" else { mergeNote = "This pull request is no longer open."; return }
            guard let head = pr["headSha"].string, let base = pr["baseRef"].string else { mergeNote = "The server did not say which commit to merge."; return }
            do {
                let v = try await store.call("merge_pull", ["repo": .string(repo), "pr": JSON(number), "headSha": .string(head), "baseRef": .string(base), "method": "squash"])
                mergeNote = v["status"].string == "pending"
                    ? "GitHub accepted the merge and is still finishing it; the pull request leaves the list once it lands." : nil
            } catch {
                if let said = failure(error) {
                    mergeNote = (error as? APIError)?.isRefusal == true ? said : "\(said) The merge may still have completed; pull down to refresh before trying again."
                }
            }
            // The other rows' Merge is back while the list is read again.
            mergingNumber = 0
            await read(fresh: true)
        }
    }

    private func activeRuns(_ number: Int) -> Int { feed.sessions.filter { $0.pullNumber == number && $0.isActive }.count }

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
