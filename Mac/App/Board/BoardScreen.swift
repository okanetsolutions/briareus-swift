// The project board (screen_pulls.c pulls_screen_*): open pull requests and issues as tabs, with the project's SSH and SFTP
// sessions beside them for a token that may read the servers. Each pull request row carries the errands its state offers,
// the suggested one filled; author, reviewer and label pickers narrow the lists, and are kept per repository.
import Combine
import SwiftUI

enum BoardTab: Int { case pulls, issues, ssh, sftp, board, run, db, forge, meeting, review, files, memories, deploy, envoyer }

@MainActor
final class BoardModel: ObservableObject {
    let repo: String
    @Published var board: JSON = .null
    @Published var pulls: [PullSummary] = []
    /// The issue rows with what the server sent for each, which is what the issue screen opens with.
    @Published var issues: [(summary: IssueSummary, raw: JSON)] = []
    @Published var tab = BoardTab.pulls
    /// The epics whose sub-issues the Issues tab hides, by number.
    @Published var foldedEpics: Set<Int> = []
    @Published var runs: [Session] = []
    @Published var syncedAt: Date?
    /// Bumped when a read is held by the cooldown, so the board reads once it is over.
    @Published var cooldownTick = 0
    @Published var pullFilter = BoardFilter()
    @Published var issueFilter = BoardFilter()
    @Published var loaded = false
    @Published var error: String?
    @Published var catalog: JSON = []
    @Published var busy = false
    @Published var uncertain = false
    @Published var startingNumber = 0
    @Published var startingID: String?
    @Published var writeError: String?
    /// The pull request being merged from its row: read for its head first, then merged.
    @Published var mergingNumber = 0
    @Published var reading = false
    /// User refreshes and post-merge reads show in-list progress until every fresh read finishes.
    @Published private var refreshCount = 0
    var refreshing: Bool { refreshCount > 0 }
    var dialogOpen = false
    /// The Board tab's own state (ProjectBoardTab.swift).
    lazy var projectBoard = ProjectBoardModel(repo: repo)
    /// The project Status of each linked issue, for the chips on the pull request rows (IssueProjects.swift).
    lazy var issueStatus = IssueStatusReader(repo: repo, rows: { [weak self] in (self?.pulls ?? [], self?.pullFilter ?? BoardFilter()) },
                                             changed: { [weak self] in self?.objectWillChange.send() })
    private var hasOpening = false
    private var opening = BoardFilter()
    var readGen = 0
    private var readingActions = false, readingRuns = false
    /// The Run, Database and Forge tabs (project_run.c, project_db.c, project_forge.c), kept with the board as the Windows
    /// client keeps them with its screen; what they change redraws the board's header.
    private(set) lazy var run = adoptTab(ProjectRunModel(repo: repo))
    private(set) lazy var db = adoptTab(ProjectDBModel(repo: repo))
    private(set) lazy var forge = adoptTab(ProjectForgeModel(repo: repo))
    /// The Files tab: the repository's tree and the files open from it (ProjectFilesTab.swift).
    private(set) lazy var files = adoptTab(ProjectFilesModel(repo: repo))
    private(set) lazy var memories = adoptTab(ProjectMemoriesModel(repo: repo))
    private(set) lazy var deployments = adoptTab(ProjectDeploymentsModel(repo: repo))
    private(set) lazy var envoyer = adoptTab(ProjectEnvoyerModel(repo: repo))
    private var tabSinks: [AnyCancellable] = []
    private func adoptTab<T: ObservableObject>(_ m: T) -> T where T.ObjectWillChangePublisher == ObservableObjectPublisher {
        tabSinks.append(m.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        return m
    }

    init(repo: String) {
        self.repo = repo
        hasOpening = !filtersRestore()
    }

    var title: String { ProjectsModel.shared.project(repo)?.title ?? repo }
    var filter: BoardFilter {
        get { tab == .pulls ? pullFilter : issueFilter }
        set { if tab == .pulls { pullFilter = newValue } else { issueFilter = newValue } }
    }
    var rows: [BoardRow] { tab == .pulls ? pulls.map(BoardRow.init) : issues.map { BoardRow($0.summary) } }

    // MARK: Filters, kept on disk per repository

    func filtersSave() {
        Store.shared.cache.store(["pulls": pullFilter.saved, "issues": issueFilter.saved], "pulls-filters:\(repo)")
    }
    /// A pick was made: the board no longer opens on the project's author, and the picks are kept.
    func picked() {
        hasOpening = false
        filtersSave()
    }
    /// A board never filtered opens on the project's author; one with saved picks opens on them.
    private func filtersRestore() -> Bool {
        guard let saved = Store.shared.cache.value("pulls-filters:\(repo)") else { return false }
        pullFilter = BoardFilter(saved: saved["pulls"]); issueFilter = BoardFilter(saved: saved["issues"])
        return true
    }

    // MARK: Reading

    func show(_ result: JSON, saved: Bool) {
        board = result
        // A poll mostly answers what is already shown; unchanged rows are left as they are.
        let parsed = PullSummary.parseList(result["pulls"])
        if parsed != pulls { pulls = parsed }
        if result["issues"] != JSON.array(issues.map(\.raw)) { issues = result["issues"].items.compactMap { j in IssueSummary(j).map { ($0, j) } } }
        // A saved board may be out of date about who has something open, so the server's first answer opens the board
        // again, unless the pickers were touched meanwhile.
        if hasOpening {
            let f = BoardFilter.opening(author: result["author"].string, rows: pulls.map(BoardRow.init))
            if pullFilter == opening { pullFilter = f }
            if saved { opening = f } else { hasOpening = false; opening = BoardFilter() }
        }
        if tab == .issues && issues.isEmpty && !result["issuesError"].isSet { tab = .pulls }
        issueStatus.restore()
        loaded = true
    }

    /// Reads the board (`fresh` asks GitHub rather than the server's copy), the errands and the project's conversations.
    @discardableResult
    func load(fresh: Bool = false) async -> APIError? {
        if fresh { refreshCount += 1 }
        defer { if fresh { refreshCount -= 1 } }
        if !loaded {
            if let saved = Store.shared.cache.value("pulls:\(repo)") { show(saved, saved: true) }
            if catalog.count == 0, let acts = Store.shared.cache.value("actions") { catalog = acts["actions"] }
        }
        if Store.shared.canManage && Store.shared.supports("actions") && !readingActions {
            readingActions = true
            Task {
                let r = await boardCall("actions")
                readingActions = false
                if let v = r.value { catalog = v["actions"]; Store.shared.cache.store(v, "actions") }
            }
        }
        if Store.shared.supports("sessions") && !readingRuns { Task { await loadRuns() } }
        return await loadBoard(fresh: fresh, ifStale: true)?.error
    }
    /// The newest read wins: after a start, C cancels the read in flight and reads again.
    private var runsGen = 0
    func loadRuns() async {
        runsGen += 1
        let gen = runsGen
        readingRuns = true
        let r = await boardCall("sessions", ["repo": .string(repo)])
        guard gen == runsGen else { return }
        readingRuns = false
        if let v = r.value, let list = Session.parseList(v) { runs = list }
    }
    /// Refreshing is how an uncertain start is checked: its conversation is listed in the project if it began.
    func refresh() {
        switch tab {
        case .ssh: RemoteSessions.sshRefresh(repo)
        case .run: run.refresh()
        case .db: db.refresh()
        case .forge: forge.refresh()
        case .sftp: RemoteSessions.sftpRefresh(repo)
        case .board: projectBoard.refresh()
        case .files: files.refresh()
        default:
            guard !refreshing else { return }
            uncertain = false; writeError = nil
            issueStatus.reset()
            Task { if !refreshing { await load(fresh: true) } }
        }
    }

    func runsOn(_ number: Int) -> Int { BoardPullRuns(runs, number: number).total }
    func runActiveOn(_ number: Int) -> Bool { BoardPullRuns(runs, number: number).active > 0 }
    func stack(of pull: PullSummary) -> StackPosition? { StackPosition(pull.raw["stack"], stacks: board["stacks"]) }
    /// Whose review the Review List waits on: the saved GitHub login, else the project's author.
    var reviewer: String? { BoardEdits.login ?? board["author"].nonEmpty }
    /// The Review List tab's rows (reviewList).
    var reviewPulls: [PullSummary] { reviewList(pulls, stacks: board["stacks"], me: reviewer) }

    // MARK: Errands

    func start(_ pull: PullSummary, _ action: BoardAction, input: String?) {
        guard !busy, !uncertain, !pull.branch.isEmpty else { return }
        busy = true; startingNumber = pull.number; startingID = action.id
        let args = action.arguments(repo: repo, number: pull.number, branch: pull.branch, input: input)
        Task {
            let r = await boardCall(action.operation, args, timeout: action.timeoutMs.map { TimeInterval($0) / 1000 })
            busy = false
            switch r {
            case .success:
                writeError = nil
                // The list stays shown; the new session joins the runs counted on its pull request.
                post(.sessionsChanged, ["repo": repo])
                if Store.shared.supports("sessions") { await loadRuns() }
            case .failure(let e):
                writeError = e.description
                // A refusal is definite; anything else may have started the session.
                if !e.isRefusal { uncertain = true }
            }
        }
    }
    func act(_ pull: PullSummary, _ action: BoardAction) {
        guard !busy, !uncertain else { return }
        if action.id == "run" { openRun(pull); return }
        afterThisEvent { [self] in
            dialogOpen = true
            let answer = actionPrompt(action, repo: repo, number: pull.number)
            dialogOpen = false
            if let input = answer { start(pull, action, input: input) }
        }
    }

    // MARK: Merge

    /// The same permission and capability rules on the project and cross-project rows.
    func rowActions(for pull: PullSummary) -> BoardPullActions {
        BoardPullActions(pull: pull, catalog: catalog, canManage: Store.shared.canManage, supports: { Store.shared.supports($0) })
    }
    /// Merging from the board: the row carries no head commit, and the server merges only the head that was read, so the
    /// pull request is read first and squash-merged at the head that read returns, once confirmed. Then the list is read
    /// again.
    func merge(_ pull: PullSummary) {
        guard mergingNumber == 0, !busy else { return }
        dialogOpen = true
        let ok = Dialogs.confirm("Merge #\(pull.number)?", boardPullMergeQuestion(pull), continueLabel: "Merge", destructive: true)
        dialogOpen = false
        guard ok, mergingNumber == 0 else { return }
        let number = pull.number
        mergingNumber = number; writeError = nil
        Task {
            defer { mergingNumber = 0 }
            let read = await boardCall("pull", ["repo": .string(repo), "pr": JSON(number)])
            if let e = read.error { if e.kind != .cancelled { writeError = e.description }; return }
            let pr = read.value?["pr"] ?? .null
            let record = PullRecord(number: number, pr: pr, row: pull)
            guard let arguments = record.mergeArguments(repo: repo) else { writeError = record.mergeBlocker?.message; return }
            let r = await boardCall("merge_pull", arguments)
            switch r {
            case .success(let v):
                writeError = v["status"].string == "pending"
                    ? "GitHub accepted the merge and is still finishing it; the pull request leaves the list once it lands." : nil
            case .failure(let e):
                writeError = e.isRefusal ? e.description : "\(e.description) The merge may still have completed; refresh before trying again."
            }
            // The other rows' Merge buttons are back while the list is read again.
            mergingNumber = 0
            await load(fresh: true)
        }
    }

    // MARK: Opening

    func openPull(_ pull: PullSummary) {
        Navigator.shared.push(.pull(repo: repo, number: pull.number, stack: stack(of: pull)?.json, summary: pull.raw))
    }
    /// "N runs ›" opens the pull request, its stack left to be read there.
    func openRuns(_ pull: PullSummary) {
        Navigator.shared.push(.pull(repo: repo, number: pull.number, stack: nil, summary: pull.raw))
    }
    /// ▶ Run opens the pull request on its Run tab.
    func openRun(_ pull: PullSummary) {
        let screen = Screen.pull(repo: repo, number: pull.number, stack: stack(of: pull)?.json, summary: pull.raw)
        let model = PullModel(repo: repo, number: pull.number, stack: stack(of: pull), summary: pull)
        model.runOpen()
        BoardModels.adopt(screen.id, model)
        Navigator.shared.push(screen)
    }
    func openIssue(_ raw: JSON) { Navigator.shared.push(.issue(repo: repo, issue: raw)) }
}

struct BoardScreen: View {
    var repo: String
    @ObservedObject private var model: BoardModel
    @ObservedObject private var store = Store.shared
    /// Which projects name a board (`hasBoard`), for the Board tab.
    @ObservedObject private var projects = ProjectsModel.shared
    @ObservedObject private var meeting = Meeting.shared
    @State private var remoteRevision = 0
    @State private var cooldownRevision = 0

    init(repo: String) {
        self.repo = repo
        model = BoardModels.model("pulls:\(repo)") { BoardModel(repo: repo) }
    }

    /// SSH and SFTP sessions only for a token that may read the servers (project_ssh_offered).
    private var remoteOffered: Bool { store.supports("settings_ssh_servers") }

    var body: some View {
        VStack(spacing: 0) {
            if model.tab == .board {
                ProjectBoardHeader(model: model.projectBoard, title: model.title, lead: meetButton, status: meeting.isFor(repo) ? meeting.status : nil)
            } else { header }
            switch model.tab {
            case .board:
                VStack(alignment: .leading, spacing: 0) {
                    tabs.padding(.horizontal, Theme.paneMargin)
                    Spacer().frame(height: 14)
                    ProjectBoardTab(model: model.projectBoard, issues: model.issues.map(\.summary), pulls: model.pulls)
                        .padding(.horizontal, Theme.paneMargin)
                }
                // A project that no longer names a board falls back to its pull requests, as the tab's button goes.
                .onReceive(projects.objectWillChange) { _ in
                    DispatchQueue.main.async { if model.tab == .board && !ProjectBoardModel.offered(repo) { model.tab = .pulls } }
                }
            case .ssh, .sftp, .run, .db, .forge, .files, .memories, .deploy, .envoyer:
                VStack(alignment: .leading, spacing: 0) {
                    tabs.padding(.horizontal, Theme.paneMargin)
                    Spacer().frame(height: 14)
                    Group {
                        switch model.tab {
                        case .ssh: ProjectSSHTab(repo: repo, showsHeader: false)
                        case .sftp: ProjectSFTPTab(repo: repo, showsHeader: false)
                        default: projectTab
                        }
                    }
                    .padding(.horizontal, Theme.paneMargin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            case .meeting:
                VStack(alignment: .leading, spacing: 0) {
                    tabs.padding(.horizontal, Theme.paneMargin)
                    Spacer().frame(height: 14)
                    MeetingTranscript(transcript: meeting.transcript(for: repo) ?? "")
                }
                .onChange(of: meeting.logRepo) { _, _ in if meeting.transcript(for: repo) == nil { model.tab = .pulls } }
            default:
                ScrollView {
                    // Lazy: a busy repository lists a hundred pull requests, and only the rows in view are built and redrawn.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        tabs
                        Spacer().frame(height: 14)
                        lists
                        Spacer().frame(height: 16)
                    }
                    .padding(.horizontal, Theme.paneMargin)
                }
            }
        }
        .task { await poll(every: 45) { await model.pollBoard() } }
        .onAppear { model.openPulls() }
        .onChange(of: model.tab) { _, _ in model.openPulls() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.refresh() }
        // A list held by the server's cooldown is read as soon as it is over.
        .task(id: model.cooldownTick) {
            guard let until = PullsGate.deadline(repo) else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(until.timeIntervalSinceNow, 0) * 1_000_000_000) + 200_000_000)
            if !Task.isCancelled { await model.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pullsCooldownChanged)) { note in
            if note.userInfo?["repo"] as? String == repo { cooldownRevision += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteSessionsChanged)) { _ in remoteRevision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .sessionForgotten)) { note in
            if let id = note.userInfo?["id"] as? String { model.runs.removeAll { $0.id == id } }
        }
        .onDisappear { BoardModels.release("pulls:\(repo)") }
    }

    // MARK: Header

    private var header: some View {
        var sub = repo
        if model.loaded { sub += " · \(model.pulls.count) open pull request\(model.pulls.count == 1 ? "" : "s")" }
        if let at = model.syncedAt { sub += " · synced \(formatRelative(at))" }
        // While GitHub's allowance is spent, when the list is read again; ⟳ waits for it too.
        _ = cooldownRevision
        let retry = PullsGate.deadline(repo)
        let retryText = retry.map { " · retry after \(formatEventTime($0))" } ?? ""
        sub += retryText
        var status: String?
        var buttons: [HeaderButton] = []
        let refresh = HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Refresh the list from GitHub",
                                   enabled: !model.reading && retry == nil, loading: model.reading) { model.refresh() }
        switch model.tab {
        case .ssh, .sftp:
            _ = remoteRevision
            let h = model.tab == .ssh ? RemoteSessions.sshHeader(repo) : RemoteSessions.sftpHeader(repo)
            if let s = h?.subtitle { sub = s }
            status = h?.status
            buttons = h?.buttons ?? []
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C),
                                        tip: model.tab == .ssh ? "Read the project's SSH servers again" : "Read the servers and the folder on show again") { model.refresh() })
        case .run:
            sub = model.run.subtitle
            buttons = model.run.headerButtons
        case .db:
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the project's SSH servers again") { model.refresh() })
        case .files:
            sub = model.files.subtitle
            buttons = model.files.headerButtons
        case .forge:
            if let s = model.forge.subtitle { sub = s }
            buttons = model.forge.headerButtons
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read it from Forge again") { model.refresh() })
        case .meeting: break
        case .memories:
            sub = "\(repo) · \(model.memories.memories.filter { !$0.archived }.count) memories"
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the memories again") { Task { await model.memories.load() } })
        case .deploy:
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the deployments from GitHub again") { Task { await model.deployments.load() } })
        case .envoyer:
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read it from Envoyer again") { Task { await model.envoyer.loadAccounts(); await model.envoyer.loadProject() } })
        case .review:
            sub = repo
            if model.loaded { sub += " · \(model.reviewPulls.count) waiting on \(model.reviewer ?? "you")" }
            if let at = model.syncedAt { sub += " · synced \(formatRelative(at))" }
            sub += retryText
            buttons.append(BoardEdits.reviewLoginButton(asking: { model.dialogOpen = $0 }) { model.objectWillChange.send() })
            buttons.append(refresh)
        default:
            buttons += BoardFilterControls.headerButtons(
                filter: model.filter, kinds: boardFilterKinds(pulls: model.tab == .pulls),
                stacked: model.tab == .pulls, enabled: model.loaded, pick: model.pick,
                toggleLaterStacked: model.toggleLaterStacked, toggleFailingChecks: model.toggleFailingChecks)
            buttons.append(refresh)
        }
        // 🎙 Meet: the meeting assistant, on this project, on every tab; a meeting about it leads the line with its time,
        // cost and what it is doing.
        if meeting.isFor(repo) { sub = "\(meeting.status) · \(sub)" }
        buttons.insert(meetButton, at: 0)
        return PaneHeader(title: model.title, subtitle: sub, status: status, buttons: buttons)
    }
    private var meetButton: HeaderButton {
        HeaderButton(glyph: "mic", label: meeting.isFor(repo) ? "🎙 Meeting ●" : "🎙 Meet",
                     tip: "Join a meeting with an assistant that can look up this project") {
            MeetingMenu.show(repo: repo, title: model.title)
        }
    }

    // MARK: Tabs

    /// `#proj-tabs`: 13px, `px-2 py-2`, the open one underlined in the accent.
    private var tabs: some View {
        _ = remoteRevision
        let open = RemoteSessions.sshCount(repo), files = RemoteSessions.sftpCount(repo)
        var labels: [(BoardTab, String)] = [(.pulls, "⇅ Pull requests"), (.issues, "⊙ Issues")]
        // Board, after Issues, for a project that names a GitHub Projects board.
        if ProjectBoardModel.offered(repo) { labels.append((.board, "▦ Board")) }
        // Review List, the pull requests waiting on the user's review, after the board.
        labels.append((.review, boardReviewTabLabel(count: model.loaded ? model.reviewPulls.count : nil)))
        // Files, the repository's tree at a branch, for a server that lists it.
        if ProjectFilesModel.offered { labels.append((.files, "🗂 Files")) }
        // Run, on the default branch, for a token that may serve one.
        if ProjectRunModel.offered { labels.append((.run, "▶ Run")) }
        if remoteOffered {
            labels.append((.ssh, open > 0 ? "❯ SSH sessions \(open)" : "❯ SSH sessions"))
            labels.append((.sftp, files > 0 ? "⇵ SFTP sessions \(files)" : "⇵ SFTP sessions"))
        }
        if ProjectDBModel.offered { labels.append((.db, "⛁ Database")) }
        if ProjectForgeModel.offered { labels.append((.forge, "☁ Forge")) }
        if ProjectMemoriesModel.offered { labels.append((.memories, "🧠 Memories")) }
        if ProjectDeploymentsModel.offered { labels.append((.deploy, "🚀 Deploy")) }
        if ProjectEnvoyerModel.offered { labels.append((.envoyer, "🚢 Envoyer")) }
        // The meeting's transcript, while one runs on this project and after it.
        if meeting.transcript(for: repo) != nil { labels.append((.meeting, meeting.isFor(repo) ? "🎙 Meeting ●" : "🎙 Meeting")) }
        return BoardTabStrip(labels: labels, active: model.tab) { select($0) }
    }
    private func select(_ tab: BoardTab) {
        model.tab = tab == .issues || tab == .review || ((tab == .ssh || tab == .sftp) && remoteOffered) || (tab == .board && ProjectBoardModel.offered(repo)) || projectTabOffered(tab) || tab == .meeting ? tab : .pulls
        if model.tab == .run { model.run.open() }
    }

    // MARK: The Run, Database and Forge tabs

    private func projectTabOffered(_ tab: BoardTab) -> Bool {
        switch tab {
        case .run: return ProjectRunModel.offered
        case .db: return ProjectDBModel.offered
        case .forge: return ProjectForgeModel.offered
        case .files: return ProjectFilesModel.offered
        case .memories: return ProjectMemoriesModel.offered
        case .deploy: return ProjectDeploymentsModel.offered
        case .envoyer: return ProjectEnvoyerModel.offered
        default: return false
        }
    }
    /// The tab on show, from the tabs down to the bottom of the pane.
    @ViewBuilder private var projectTab: some View {
        switch model.tab {
        case .run: ProjectRunTab(model: model.run)
        case .db: ProjectDBTab(model: model.db)
        case .forge: ProjectForgeTab(model: model.forge)
        case .files: ProjectFilesTab(model: model.files)
        case .memories: ProjectMemoriesTab(model: model.memories)
        case .deploy: ProjectDeploymentsTab(model: model.deployments)
        case .envoyer: ProjectEnvoyerTab(model: model.envoyer)
        default: EmptyView()
        }
    }

    // MARK: Lists

    @ViewBuilder private var lists: some View {
        BoardListFeedback(error: model.error, writeError: model.writeError, uncertain: model.uncertain,
                          loading: boardShowsLoading(loaded: model.loaded, refreshing: model.refreshing), loadingText: model.loadingText)
        if model.tab == .review { reviewList } else { filteredLists }
    }

    @ViewBuilder private var filteredLists: some View {
        let filter = model.filter
        let rows = model.rows
        let shown = rows.filter { filter.passes($0) }.count
        if filter.isOn {
            HStack {
                Text(verbatim: "Showing \(shown) of \(rows.count)").font(Theme.caption).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Button("Clear filters") { model.clearFilters() }.buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.accent).handCursor()
            }
            .frame(height: 20).padding(.bottom, 8)
        }
        if model.tab == .pulls { pullList(filter: filter, shown: shown) } else { issueList(filter: filter, shown: shown) }
    }

    /// The pull requests waiting on the user's review: labelled requires-dev-review, not theirs, and not stacked on
    /// another, or labelled feedback-implemented on one they review.
    @ViewBuilder private var reviewList: some View {
        let shown = model.reviewPulls
        ForEach(shown, id: \.number) { pull in
            BoardPullListRow(model: model, pull: pull, stack: model.stack(of: pull)) { model.openPull(pull) }
            .padding(.bottom, 8)
        }
        if !boardShowsLoading(loaded: model.loaded, refreshing: model.refreshing) && shown.isEmpty && model.error == nil {
            Text(model.reviewer == nil ? "Set your GitHub login to see the pull requests waiting on your review." : "Nothing is waiting on your review.")
                .font(Theme.footnote).foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder private func pullList(filter: BoardFilter, shown: Int) -> some View {
        ForEach(model.pulls.filter { filter.passes(BoardRow($0)) }, id: \.number) { pull in
            BoardPullListRow(model: model, pull: pull, stack: model.stack(of: pull)) { model.openPull(pull) }
            .padding(.bottom, 8)
        }
        if !boardShowsLoading(loaded: model.loaded, refreshing: model.refreshing) && shown == 0 && model.error == nil {
            Text(model.pulls.isEmpty ? "No open pull requests." : "No pull requests match the filters.").font(Theme.footnote).foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder private func issueList(filter: BoardFilter, shown: Int) -> some View {
        if let refused = model.board["issuesError"].string {
            BoardBox(padding: 12, radius: 10) {
                Text("GitHub would not read this repository’s issues with the server’s token. A fine-grained token needs Issues: read. The pull requests are unaffected.")
                    .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Notice(message: refused).padding(.top, 6)
            }
        } else {
            let visible = model.issues.indices.filter { filter.passes(BoardRow(model.issues[$0].summary)) }
            let summaries = visible.map { model.issues[$0].summary }
            let nested = issuesFolded(issuesNested(summaries, repo: repo), summaries, folded: model.foldedEpics)
            ForEach(Array(nested.enumerated()), id: \.offset) { _, row in
                let i = visible[row.index]
                let depth = min(row.depth, 4)
                let number = model.issues[i].summary.number
                IssueRowView(issue: model.issues[i].summary, repo: repo, nested: depth > 0,
                             folded: row.children > 0 ? model.foldedEpics.contains(number) : nil,
                             fold: { if model.foldedEpics.remove(number) == nil { model.foldedEpics.insert(number) } }) {
                    model.openIssue(model.issues[i].raw)
                }
                    .padding(.leading, CGFloat(depth) * 18)
                    .padding(.bottom, 8)
            }
            if model.board["issuesTruncated"].is(true) {
                Text("This repository has more open issues; only the most recently updated are listed.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !boardShowsLoading(loaded: model.loaded, refreshing: model.refreshing) && shown == 0 && model.error == nil {
                Text(model.issues.isEmpty ? "No open issues." : "No issues match the filters.").font(Theme.footnote).foregroundStyle(Theme.muted)
            }
        }
    }
}
