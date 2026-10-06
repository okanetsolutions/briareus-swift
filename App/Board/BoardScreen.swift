// A project's board on a phone (the Mac's BoardScreen): open pull requests and issues behind a segmented control, and
// for a project that names one, its GitHub Projects board (ProjectBoardTab.swift); the author, reviewer (pull requests),
// assignee (issues, No assignee among them) and label pickers in the toolbar's filter menu, kept per repository. Each pull
// request row names the errand its state asks for and offers the errands in its context menu, and its linked issues end
// with their project Status, and a swipe to its right merges it, once confirmed with what stands in the way. The Mac's
// SSH and SFTP tabs are left out: they drive local ssh and sftp processes a phone does not have.
import SwiftUI

/// The board's pickers, kept on disk per repository as the Mac keeps them. A board never filtered opens on the project's
/// configured author, while they have something open.
@MainActor
final class BoardFilters: ObservableObject {
    let repo: String
    @Published var pulls = BoardFilter()
    @Published var issues = BoardFilter()
    /// The filter the board last opened on, until the server has answered once and the picks are the user's.
    private var opening: BoardFilter?

    init(repo: String) {
        self.repo = repo
        if let saved = Store.shared.cache.value("pulls-filters:\(repo)") {
            read(&pulls, saved["pulls"]); read(&issues, saved["issues"])
        } else {
            opening = BoardFilter()
        }
    }

    private func read(_ f: inout BoardFilter, _ j: JSON) {
        for k in FilterKind.allCases { if let v = j[k.name].string { f.set(k, v) } }
    }
    private func json(_ f: BoardFilter) -> JSON {
        var j: JSON = [:]
        for k in FilterKind.allCases where !f[k].isEmpty { j[k.name] = .string(f[k]) }
        return j
    }
    /// A pick by the user: the board no longer opens on the author, and the picks are saved.
    func picked() {
        opening = nil
        Store.shared.cache.store(["pulls": json(pulls), "issues": json(issues)], "pulls-filters:\(repo)")
    }
    /// A board shown before the server answered may be out of date about who has something open, so the server's answer
    /// opens it again, unless the pickers were touched meanwhile.
    func opened(_ board: JSON, answered: Bool) {
        guard let last = opening, board.isObject else { return }
        let f = BoardFilter.opening(author: board["author"].string, rows: PullSummary.parseList(board["pulls"]).map(BoardRow.init))
        if pulls == last { pulls = f }
        opening = answered ? nil : f
    }
}

struct BoardScreen: View {
    let repo: String
    private enum Tab: Hashable { case pulls, issues, projectBoard }

    @EnvironmentObject private var store: Store
    @ObservedObject private var feed: ProjectFeed
    @ObservedObject private var catalog = ErrandCatalog.shared
    @ObservedObject private var projects = ProjectsModel.shared
    @StateObject private var filters: BoardFilters
    @StateObject private var errands: ErrandRunner
    @StateObject private var projectBoard: ProjectBoardModel
    @StateObject private var issueStatus: IssueStatusReader
    @State private var tab = Tab.pulls
    @State private var error: String?
    /// The pull request whose Merge waits for a yes, the one being merged from its row, and what the last merge left to say.
    @State private var mergeAsked: PullSummary?
    @State private var mergingNumber = 0
    @State private var mergeNote: String?

    init(repo: String) {
        self.repo = repo
        feed = Store.shared.feed(repo)
        _filters = StateObject(wrappedValue: BoardFilters(repo: repo))
        _errands = StateObject(wrappedValue: ErrandRunner(repo: repo))
        _projectBoard = StateObject(wrappedValue: ProjectBoardModel(repo: repo))
        _issueStatus = StateObject(wrappedValue: IssueStatusReader(repo: repo))
    }

    private var board: JSON { feed.board }
    private var pulls: [PullSummary] { PullSummary.parseList(board["pulls"]) }
    private var issues: [(summary: IssueSummary, raw: JSON)] { board["issues"].items.compactMap { j in IssueSummary(j).map { ($0, j) } } }
    private var loaded: Bool { feed.boardLoaded || error != nil }
    private var filter: Binding<BoardFilter> { shownTab == .pulls ? $filters.pulls : $filters.issues }
    /// The project names a GitHub Projects board this token can read.
    private var boardOffered: Bool { ProjectBoardModel.offered(repo) }
    /// The tab shown: the Board tab falls back to the pull requests once the project no longer names a board.
    private var shownTab: Tab { tab == .projectBoard && !boardOffered ? .pulls : tab }

    var body: some View {
        let pulls = self.pulls, issues = self.issues
        let tab = shownTab
        let rows = tab == .pulls ? pulls.map(BoardRow.init) : issues.map { BoardRow($0.summary) }
        List {
            if let error { Section { ErrorNotice(message: error) }.listRowBackground(Theme.row) }
            ErrandNotice(runner: errands, place: "in the project")
            if let note = mergeNote { Section { ErrorNotice(message: note) }.listRowBackground(Theme.row) }
            Picker("Show", selection: $tab) {
                // Three segments share a phone's width, so the pull requests go by their short name beside the board.
                Text("\(boardOffered ? "PRs" : "Pull requests") (\(pulls.count))").tag(Tab.pulls)
                Text("Issues (\(issues.count))").tag(Tab.issues)
                if boardOffered { Text("Board").tag(Tab.projectBoard) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            if tab == .projectBoard {
                ProjectBoardSection(model: projectBoard, issues: issues.map(\.summary), pulls: pulls)
            } else if filter.wrappedValue.isOn {
                HStack {
                    Text("Showing \(rows.filter { filter.wrappedValue.passes($0) }.count) of \(rows.count)").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear filters") { filter.wrappedValue = BoardFilter(); filters.picked() }.font(.footnote).buttonStyle(.borderless)
                }
                .listRowBackground(Color.clear)
            }
            if tab == .pulls { pullRows(pulls) } else if tab == .issues { issueRows(issues) }
            if !loaded && tab != .projectBoard {
                ProgressView("Loading pull requests…").frame(maxWidth: .infinity).padding(.vertical, 24).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle(projects.project(repo)?.title ?? "Board").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if tab == .projectBoard {
                    ProjectBoardMenu(model: projectBoard).disabled(projectBoard.board == nil)
                } else {
                    BoardFilterMenu(filter: filter, rows: rows, kinds: tab == .pulls ? [.author, .reviewer, .label] : [.author, .assignee, .label]) { filters.picked() }
                        .disabled(!loaded || rows.isEmpty && !filter.wrappedValue.isOn)
                }
            }
        }
        .refreshable {
            // Pulling down is how an uncertain start is checked: its conversation shows on its pull request if it began.
            errands.checked()
            if tab == .projectBoard {
                // The board's cards name the pull requests closing them from the pull requests' read, so both are read.
                async let pulls: Void = read(fresh: false)
                await projectBoard.refresh()
                _ = await pulls
                return
            }
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
        // The Projects board is read while its tab is on show, as often as the pull requests are.
        .task(id: tab == .projectBoard) {
            guard tab == .projectBoard else { return }
            await poll(every: ProjectFeed.boardEvery) { await reading { try await projectBoard.load() } }
        }
        // Each linked issue's Status, one read at a time while the board is on show, the rows the filters show first.
        .onAppear { issueStatus.shown = true; issueStatus.next(pulls: self.pulls, filter: filters.pulls) }
        .onDisappear { issueStatus.shown = false }
        .alert("The card could not be moved", isPresented: Binding(get: { projectBoard.moveAlert != nil }, set: { if !$0 { projectBoard.moveAlert = nil } }),
               presenting: projectBoard.moveAlert) { _ in
            Button("OK", role: .cancel) {}
        } message: { reason in
            Text(reason + " The board shows the card where GitHub has it.")
        }
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

    private func load(fresh: Bool = false) async throws {
        do {
            try await feed.loadBoard(fresh: fresh)
            filters.opened(board, answered: true)
            error = nil
            issueStatus.next(pulls: pulls, filter: filters.pulls)
        } catch {
            if let said = failure(error) { self.error = said }
            throw error
        }
    }
    private func read(fresh: Bool) async { _ = await reading { try await load(fresh: fresh) } }

    // MARK: Pull requests

    @ViewBuilder private func pullRows(_ pulls: [PullSummary]) -> some View {
        let shown = pulls.filter { filters.pulls.passes(BoardRow($0)) }
        Section {
            ForEach(shown, id: \.number) { pull in
                let stack = StackPosition(pull.raw["stack"], stacks: board["stacks"])
                let actions = pull.branch.isEmpty ? [] : boardErrands(catalog: catalog.catalog, pull: pull, failedChecks: 0)
                DestinationLink(destination: .pull(repo: repo, number: pull.number, stack: stack?.json, summary: pull.raw)) {
                    BoardPullRow(pull: pull, stack: stack, repo: repo, activeRuns: activeRuns(pull.number),
                                 suggested: actions.first { $0.id == pull.recommended }?.label, issueStatus: issueStatus.statuses(pull))
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
        if loaded && shown.isEmpty && error == nil {
            ContentUnavailableView(pulls.isEmpty ? "No open pull requests" : "No pull requests match the filters", systemImage: "arrow.triangle.pull")
                .listRowBackground(Color.clear)
        }
    }

    /// The row's errands as the Mac's row buttons offer them, less ▶ Run, which is the pull request's own Run tab.
    @ViewBuilder private func rowMenu(_ pull: PullSummary, actions: [BoardAction]) -> some View {
        let errandList = actions.filter { $0.id != "run" }
        if !errandList.isEmpty {
            Section("Errands") {
                ForEach(errandList, id: \.id) { a in
                    Button(role: a.id == "delete-self-comments" ? .destructive : nil) {
                        errands.ask(a, number: pull.number, branch: pull.branch)
                    } label: {
                        Label(pull.recommended == a.id ? "\(a.label) (suggested)" : a.label, systemImage: pull.recommended == a.id ? "sparkles" : errandSymbol(a.id))
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
            let nested = issuesNested(visible.map(\.summary), repo: repo)
            Section {
                ForEach(nested, id: \.index) { row in
                    let item = visible[row.index]
                    DestinationLink(destination: .issue(repo: repo, issue: item.raw)) {
                        BoardIssueRow(issue: item.summary, repo: repo, nested: row.depth > 0)
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
            if loaded && visible.isEmpty && error == nil {
                ContentUnavailableView(issues.isEmpty ? "No open issues" : "No issues match the filters", systemImage: "smallcircle.filled.circle")
                    .listRowBackground(Color.clear)
            }
        }
    }
}

/// The board's pickers in one menu. Each option says how many rows picking it would leave.
private struct BoardFilterMenu: View {
    @Binding var filter: BoardFilter
    let rows: [BoardRow]
    let kinds: [FilterKind]
    let picked: () -> Void

    var body: some View {
        Menu {
            ForEach(kinds, id: \.self) { kind in
                let options = filter.options(kind, rows: rows)
                Picker(selection: Binding(get: { filter[kind] }, set: { filter.set(kind, $0); picked() })) {
                    Text("All \(kind.name)s").tag("")
                    ForEach(options, id: \.value) { Text("\($0.text) (\($0.count))").tag($0.value) }
                } label: {
                    let name = kind.name.asciiCapitalized
                    Label(filter[kind].isEmpty ? name : "\(name): \(options.first { $0.value == filter[kind] }?.text ?? filter[kind])",
                          systemImage: kind == .author ? "person" : kind == .reviewer ? "eye" : kind == .assignee ? "person.crop.circle" : "tag")
                }
                .pickerStyle(.menu)
                .disabled(options.isEmpty)
            }
            if filter.isOn {
                Button("Clear filters", systemImage: "xmark.circle", role: .destructive) { filter = BoardFilter(); picked() }
            }
        } label: {
            Image(systemName: filter.isOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(filter.isOn ? "Filters, active" : "Filters")
    }
}
