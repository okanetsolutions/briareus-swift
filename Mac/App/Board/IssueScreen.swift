// One issue as GitHub lays its page out (screen_pulls.c issue_detail_screen_*): the title with its state and who opened it,
// the body, an epic's sub-issues, the conversations started on it and the timeline, beside GitHub's sidebar when the pane
// is wide. The issue is read in full (`issue`) with its timeline (`issue_timeline`) a page at a time; the board is still
// read beside it on a timer for the rows of the open sub-issues, which carry their own facts. On a server without the
// issue's own read, the board's row is all the screen has.
import SwiftUI

@MainActor
final class IssueModel: ObservableObject {
    let repo: String
    @Published var issue: IssueSummary
    @Published var boardIssues: [(summary: IssueSummary, raw: JSON)] = []
    @Published var boardPulls: [PullSummary] = []
    @Published var boardRead = false
    /// The board was read and this issue is not on it.
    @Published var gone = false
    @Published var loadError: String?
    /// The issue in full: its body, type, projects, every sub-issue and linked pull request. Null until read.
    @Published var detail: JSON = .null
    @Published var detailError: String?
    /// Every sub-issue the full read lists, closed ones and other repositories' included.
    @Published var subs: [BoardLink] = []
    /// The timeline pages read so far, oldest first; nil until the first is in.
    @Published var events: [JSON]?
    /// The timeline's next page; 0 once it is all read.
    @Published var nextPage = 0
    @Published var timelineError: String?
    @Published private(set) var readingTimeline = false
    /// The conversations started on this issue or on a pull request closing it.
    @Published var runs: [Session] = []
    @Published var busy = false
    @Published var uncertain = false
    @Published var writeError: String?
    /// Its title, description, labels or assignees are being saved. A failed edit has a notice of its own, so it leaves an
    /// uncertain start's notice up.
    @Published var editing = false
    @Published var editError: String?
    @Published var closing = false
    /// This screen closed it; the board no longer lists it.
    @Published var closed = false
    @Published var closedReason: String?
    @Published private(set) var readingBoard = false
    @Published private(set) var readingDetail = false
    private var timelineRead = false
    /// The issue's updatedAt the timeline was read at, and the one it is being read at.
    private var timelineSeen: String?, timelineWant: String?
    private var boardGen = 0, runsGen = 0, detailGen = 0, timelineGen = 0

    init(repo: String, issue: IssueSummary) {
        self.repo = repo; self.issue = issue
        // The board as last saved fills the sub-issues in before the first read answers.
        if let saved = Store.shared.cache.value("pulls:\(repo)") { show(saved, saved: true) }
        // So does the issue's own read, body and timeline, as last seen.
        if Store.shared.supports("issue"), let saved = Store.shared.cache.value(cacheKey("issue")) { showDetail(saved["issue"]) }
        if Store.shared.supports("issue_timeline"), let saved = Store.shared.cache.value(cacheKey("issue-timeline")) { showTimeline(saved, first: true) }
    }

    var id: String { "issue:\(repo)#\(issue.number)" }
    private func cacheKey(_ what: String) -> String { "\(what):\(repo)#\(issue.number)" }

    /// Takes the board's answer: its rows, and this issue's own row when it is still there and its full read is not. A
    /// saved board only fills in.
    private func show(_ board: JSON, saved: Bool) {
        boardIssues = board["issues"].items.compactMap { j in IssueSummary(j).map { ($0, j) } }
        boardPulls = PullSummary.parseList(board["pulls"])
        var found = false
        for row in board["issues"].items where row["number"].number.map({ Int($0) }) == issue.number {
            found = true
            if !saved, detail.isNull, let fresh = IssueSummary(row) { issue = fresh }
            break
        }
        // A board GitHub refused the issues of says nothing about this one.
        if !saved { gone = !found && !board["issuesError"].isSet }
        boardRead = true
    }
    /// Takes the issue's own read: the row it shares with the board, and all the board does not carry.
    private func showDetail(_ value: JSON) {
        guard let fresh = IssueSummary(value), fresh.number == issue.number else { return }
        issue = fresh
        detail = value
        subs = BoardLink.parseList(value["subIssues"]["items"])
    }
    private func showTimeline(_ result: JSON, first: Bool) {
        var all = first ? [] : (events ?? [])
        all.append(contentsOf: result["events"].items)
        events = all
        nextPage = result["nextPage"].int32 ?? 0
    }

    @discardableResult
    func load(fresh: Bool = false) async -> APIError? {
        if Store.shared.supports("sessions") { Task { await loadRuns() } }
        if Store.shared.supports("issue") && !readingDetail { Task { await loadDetail() } }
        guard Store.shared.supports("pulls") else { return nil }
        boardGen += 1
        let gen = boardGen
        readingBoard = true
        var args: JSON = ["repo": .string(repo)]
        if fresh { args["fresh"] = "1" }
        let r = await boardCall("pulls", args)
        guard gen == boardGen else { return nil }
        readingBoard = false
        switch r {
        case .success(let v):
            show(v, saved: false)
            loadError = nil
            Store.shared.cache.store(v, "pulls:\(repo)")
            return nil
        case .failure(let e):
            if e.kind == .cancelled { return e }
            if fresh && e.kind == .http && e.status == 400 { return await load(fresh: false) }
            loadError = e.description
            return e
        }
    }
    private func loadDetail() async {
        detailGen += 1
        let gen = detailGen
        readingDetail = true
        let r = await boardCall("issue", ["issue": JSON(issue.number), "repo": .string(repo)])
        guard gen == detailGen else { return }
        readingDetail = false
        switch r {
        case .success(let v):
            showDetail(v["issue"])
            detailError = nil
            Store.shared.cache.store(v, cacheKey("issue"))
            // The timeline is read again only when the issue has moved since; the later pages read stay until then.
            let updated = detail["updatedAt"].string
            if !timelineRead || updated == nil || updated != timelineSeen { timelineWant = updated; loadTimeline(page: 1) }
        case .failure(let e):
            if e.kind != .cancelled { detailError = e.description }
        }
    }
    func loadTimeline(page: Int) {
        guard Store.shared.supports("issue_timeline") else { return }
        timelineGen += 1
        let gen = timelineGen
        readingTimeline = true
        Task {
            let r = await boardCall("issue_timeline", ["issue": JSON(issue.number), "repo": .string(repo), "page": JSON(page)])
            guard gen == timelineGen else { return }
            readingTimeline = false
            switch r {
            case .success(let v):
                showTimeline(v, first: page <= 1)
                if page <= 1 {
                    timelineSeen = timelineWant
                    Store.shared.cache.store(v, cacheKey("issue-timeline"))
                }
                timelineRead = true
                timelineError = nil
            case .failure(let e):
                if e.kind != .cancelled { timelineError = e.description }
            }
        }
    }
    func moreActivity() { if nextPage > 0 && !readingTimeline { loadTimeline(page: nextPage) } }
    func loadRuns() async {
        runsGen += 1
        let gen = runsGen
        guard let v = await boardCall("sessions", ["repo": .string(repo)]).value, gen == runsGen, let all = Session.parseList(v) else { return }
        runs = all.filter { issueRunMatches($0, issue: issue, repo: repo) }
    }
    /// F5: the issue and its timeline are read again, whatever was in flight.
    func refresh() {
        detailGen += 1; readingDetail = false
        timelineSeen = nil
        editError = nil
        Task { await load(fresh: true) }
    }

    // MARK: Edits

    /// Edit, Edit labels… and Edit assignees ▾, while the server takes `update_issue` and this screen has not closed it.
    var editable: Bool { Store.shared.supports("update_issue") && !closed }
    /// Sends `fields` as an edit of this issue. The title and description show as saved at once; reading it again brings
    /// the rest, after the read already under way is dropped, since it may have been made before the edit.
    func edit(_ fields: JSON?) {
        guard var args = fields, !editing else { return }
        editing = true; editError = nil
        args["issue"] = JSON(issue.number); args["repo"] = .string(repo)
        Task {
            let r = await boardCall("update_issue", args)
            editing = false
            switch r {
            case .success(let v):
                editError = nil
                if let title = v["issue"]["title"].string { issue.title = title }
                if let body = v["issue"]["body"].string, !detail.isNull, args["body"].isSet { detail["body"] = .string(body) }
                detailGen += 1; readingDetail = false
                await load(fresh: true)
            case .failure(let e):
                // An edit sets what it names, so trying again is safe.
                if e.kind != .cancelled { editError = e.description }
            }
        }
    }
    /// The description is the issue's own read; without it an edit would start from nothing.
    func editDetails() {
        guard !editing, let body = detail["body"].string else { return }
        edit(BoardEdits.details("issue", number: issue.number, title: issue.title, body: body))
    }
    func editAssignees() {
        guard !editing, let list = BoardEdits.assignees(issue.assignees, number: issue.number) else { return }
        edit(["assignees": BoardEdits.list(list)])
    }
    func editLabels() {
        guard !editing, let list = BoardEdits.labels(issue.labels, number: issue.number) else { return }
        edit(["labels": BoardEdits.list(list)])
    }

    var runActive: Bool { runs.contains { $0.isActive } }
    var state: IssuePageState { IssuePageState(detail: detail, closedHere: closed, closedReason: closedReason, gone: gone) }

    func start() {
        // The screen already says the session is paid and whether one is at work on it, so it starts without asking.
        guard !busy, !uncertain else { return }
        busy = true
        let args: JSON = ["repo": .string(repo), "prompt": .string(issuePrompt(issue, repo: repo)), "activity": "issue"]
        Task {
            let r = await boardCall("start_session", args)
            busy = false
            switch r {
            case .success(let v):
                post(.sessionsChanged, ["repo": repo])
                // The new conversation joins the Sessions list on the way back.
                if Store.shared.supports("sessions") { Task { await loadRuns() } }
                if let s = Session(v["session"]) { Navigator.shared.push(.conversation(id: s.id, session: s.raw)) }
            case .failure(let e):
                writeError = e.description
                if !e.isRefusal { uncertain = true }
            }
        }
    }

    /// The ▾ menu: why it is closed, and whether a comment goes first. Then a confirmation naming what stays open.
    func close() {
        guard !closing, !closed else { return }
        let items = [BoardPopupMenu.Item(title: "Close as completed"), BoardPopupMenu.Item(title: "Close as not planned"), .divider,
                     BoardPopupMenu.Item(title: "Close as completed with a comment…"), BoardPopupMenu.Item(title: "Close as not planned with a comment…")]
        guard let chosen = BoardPopupMenu.show(items) else { return }
        let notPlanned = chosen == 1 || chosen == 4
        var comment: String?
        if chosen >= 3 {
            guard let c = Dialogs.text("Comment on #\(issue.number) before closing it", label: "Comment", okLabel: "Next") else { return }
            comment = c.cTrimmed.isEmpty ? nil : c
        }
        let open = issue.subIssues - issue.subIssuesDone
        var why = ""
        if open > 0 { why += "\(open) of its sub-issues \(open == 1 ? "is" : "are") still open and stay\(open == 1 ? "s" : "") open. " }
        if runActive { why += "A session is still working on it; closing does not stop it. " }
        if comment != nil { why += "Your comment is posted first." }
        guard Dialogs.confirm("Close issue #\(issue.number) as \(notPlanned ? "not planned" : "completed")?", why.isEmpty ? nil : why, continueLabel: "Close issue"),
              !closed else { return }
        closing = true; writeError = nil
        var args: JSON = ["issue": JSON(issue.number), "repo": .string(repo), "reason": .string(notPlanned ? "not_planned" : "completed")]
        if let comment { args["comment"] = .string(comment) }
        Task {
            let r = await boardCall("close_issue", args)
            closing = false
            switch r {
            case .success(let v):
                closed = true; gone = false
                closedReason = v["issue"]["stateReason"].string ?? (notPlanned ? "not_planned" : "completed")
                writeError = nil
                // The board drops it; reading it again keeps the epic's counts and its siblings true.
                await load(fresh: true)
            case .failure(let e):
                // Closing twice only restates the reason, so trying again is safe.
                writeError = e.description
            }
        }
    }

    /// An issue of this repository opens here, from its board row when it has one; any other on GitHub.
    func openLink(_ link: BoardLink) {
        if !link.isForeign(repo) {
            if let row = boardIssues.first(where: { $0.summary.number == link.number }) { Navigator.shared.push(.issue(repo: repo, issue: row.raw)); return }
            if Store.shared.supports("issue") {
                var bare: JSON = ["number": JSON(link.number), "title": .string(link.title)]
                if let url = link.url { bare["url"] = .string(url) }
                Navigator.shared.push(.issue(repo: repo, issue: bare))
                return
            }
        }
        openWebURL(link.url)
    }
    func openPull(_ link: BoardLink) {
        if link.isForeign(repo) || !Store.shared.supports("pull") { openWebURL(link.url); return }
        Navigator.shared.push(.pull(repo: repo, number: link.number, stack: nil, summary: pullsFind(boardPulls, link.number)?.raw))
    }
    /// Where clicking an event goes: a comment's place on GitHub, the issue, pull request or commit it points to.
    func openEvent(_ e: JSON) {
        if e["kind"].string == "commented" { openWebURL(e["url"].string); return }
        let ref = e["source"].isSet ? e["source"] : e["issue"]
        if let link = BoardLink(ref) {
            if ref["kind"].string == "pull" { openPull(link) } else { openLink(link) }
            return
        }
        openWebURL(e["commit"]["url"].string)
    }
}

struct IssueScreen: View {
    var repo: String
    var issue: JSON
    @ObservedObject private var model: IssueModel
    @ObservedObject private var store = Store.shared

    init(repo: String, issue: JSON) {
        self.repo = repo; self.issue = issue
        let n = issue["number"].int ?? 0
        model = BoardModels.model("issue:\(repo)#\(n)") {
            IssueModel(repo: repo, issue: IssueSummary(issue) ?? IssueSummary(["number": JSON(max(n, 1))])!)
        }
    }

    var body: some View {
        let issue = model.issue
        VStack(spacing: 0) {
            PaneHeader(title: "#\(issue.number)", subtitle: repo, buttons: [
                HeaderButton(glyph: Glyph.symbol(0xE8C8), tip: "Copy the issue’s link", enabled: safeWebURL(issue.url)) { if safeWebURL(issue.url), let u = issue.url { Clipboard.copy(u) } },
                HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the issue from GitHub again", enabled: !model.readingBoard && !model.readingDetail) { model.refresh() },
            ])
            GeometryReader { geo in
                let w = geo.size.width - 2 * Theme.paneMargin
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer().frame(height: 14)
                        notices
                        IssueHeader(model: model).padding(.horizontal, 4)
                        Spacer().frame(height: 18)
                        if w >= 880 {
                            // Wide: the issue and its timeline on the left, GitHub's sidebar on the right.
                            let side = min(max(w * 26 / 100, 240), 320)
                            HStack(alignment: .top, spacing: 28) {
                                IssueMain(model: model).frame(maxWidth: .infinity, alignment: .topLeading)
                                IssueSidebar(model: model).frame(width: side).padding(.top, -14)
                            }
                        } else {
                            IssueMain(model: model)
                            Spacer().frame(height: 6)
                            IssueSidebar(model: model).padding(.horizontal, 4)
                        }
                        Spacer().frame(height: 16)
                    }
                    .padding(.horizontal, Theme.paneMargin)
                }
            }
        }
        .task { await poll(every: 45) { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.refresh() }
        .onDisappear { BoardModels.release(model.id) }
    }

    @ViewBuilder private var notices: some View {
        if let e = model.writeError {
            BoardBox {
                Notice(message: e)
                if model.uncertain {
                    Text("The request may have completed. Check the project’s conversations before starting another agent.")
                        .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    Button("I have checked") { model.uncertain = false; model.writeError = nil }.dashButton(.bordered).padding(.top, 8)
                }
            }
            .padding(.bottom, 10)
        }
        if let e = model.editError { Notice(message: e).padding(.bottom, 10) }
        if let e = model.detailError { Notice(message: e).padding(.bottom, 10) }
        if let e = model.loadError, e != model.detailError { Notice(message: e).padding(.bottom, 10) }
        if model.closed {
            BoardBox {
                GlyphLabel(glyph: 0xE73E, text: model.closedReason == "not_planned" ? "Closed as not planned" : "Closed as completed", color: Theme.ok)
                Text("It has left the board. Reopen it on GitHub if it was closed by mistake.").font(Theme.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            .padding(.bottom, 10)
        } else if model.gone && model.detail.isNull {
            BoardBox {
                GlyphLabel(glyph: 0xE946, text: "This issue is no longer on the board")
                Text("It was closed, or it is past the most recently updated issues the server reads. What is shown is how it was last seen.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            .padding(.bottom, 10)
        }
    }
}

// MARK: - Title block

/// The title with its number and the buttons beside it, then the state pill and GitHub's sentence: who opened it, when,
/// and its comments.
private struct IssueHeader: View {
    @ObservedObject var model: IssueModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Beside the title when there is room, above it when there is not.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    title.frame(minWidth: 320, alignment: .leading)
                    toolbar.padding(.top, 3).fixedSize()
                }
                VStack(alignment: .leading, spacing: 12) {
                    toolbar
                    title
                }
            }
            Spacer().frame(height: 10)
            HStack(alignment: .top, spacing: 0) {
                let state = model.state
                StatePill(text: state.text, color: state == .open ? Theme.ok : state == .closed ? Theme.accent : Theme.muted)
                WordFlow(runs: sentence, lineHeight: 26).padding(.leading, 10)
            }
        }
    }

    private var title: some View {
        (Text(model.issue.title + " ").foregroundStyle(Theme.ink) + Text(verbatim: "#\(model.issue.number)").foregroundStyle(Theme.muted))
            .font(Theme.title).lineSpacing(6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    @ViewBuilder private var toolbar: some View {
        if model.editable || safeWebURL(model.issue.url) {
            HStack(spacing: 6) {
                if model.editable {
                    Button(model.editing ? "Saving…" : "Edit") { model.editDetails() }.dashButton(.bordered)
                        .disabled(model.editing || model.detail["body"].string == nil).help("Edit the title and description")
                }
                if safeWebURL(model.issue.url) { Button("Open in GitHub ↗") { openWebURL(model.issue.url) }.dashButton(.bordered) }
            }
        }
    }

    private var sentence: [FlowRun] {
        let issue = model.issue
        var runs: [FlowRun] = []
        if let author = issue.author { runs.append(FlowRun(text: author + " ", font: Theme.footnoteSemibold, color: Theme.ink)) }
        if let at = issue.createdAt {
            runs.append(FlowRun(text: "\(issue.author != nil ? "opened this issue" : "Opened") \(formatRelative(at)) ", font: Theme.footnote, color: Theme.muted))
        }
        if model.state.isClosed, let at = boardDateParse(model.detail["closedAt"].string) {
            runs.append(FlowRun(text: "· closed \(formatRelative(at)) ", font: Theme.footnote, color: Theme.muted))
        }
        if issue.comments > 0 {
            runs.append(FlowRun(text: "· \(issue.comments) comment\(issue.comments == 1 ? "" : "s")", font: Theme.footnote, color: Theme.muted))
        }
        return runs
    }
}

// MARK: - Main column

/// The issue's body, an epic's sub-issues, its conversations and its timeline.
private struct IssueMain: View {
    @ObservedObject var model: IssueModel
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.supports("issue") { description }
            if model.issue.isEpic { subIssues }
            sessions
            IssueActivity(model: model)
        }
    }

    /// The opening comment: the issue's body as GitHub shows it.
    private var description: some View {
        let issue = model.issue
        let did = issue.author != nil ? "opened" : "Description"
        let when = issue.createdAt.map { "\(did) · \(formatRelative($0))" } ?? did
        return CommentBox(head: CommentHead(author: issue.author, when: when), bottom: 16) {
            if model.detail.isNull {
                Text(model.detailError != nil ? "The description could not be read." : "Loading the description…").font(Theme.callout).foregroundStyle(Theme.muted)
            } else {
                let t = visibleMarkdown(model.detail["body"].string ?? "")
                if t.isEmpty { Text("No description provided.").font(Theme.callout.italic()).foregroundStyle(Theme.muted) }
                else { MarkdownView(source: t, size: .callout) }
            }
        }
    }

    /// An epic's sub-issues: the open ones on the board drawn as the board draws them, every other one as a link.
    @ViewBuilder private var subIssues: some View {
        let issue = model.issue
        let open = issue.subIssues - issue.subIssuesDone
        let rich = issueOpenSubIssues(model.boardIssues.map(\.summary), epic: issue.number, repo: model.repo)
        // The full read lists them all; those not drawn above go in one box of links, closed ones included.
        let rest = model.subs.indices.filter { i in
            !rich.contains { k in !model.subs[i].isForeign(model.repo) && model.boardIssues[k].summary.number == model.subs[i].number }
        }
        SectionTitle(title: "Sub-issues")
        Text(verbatim: "\(issue.subIssuesDone) of \(issue.subIssues) completed").font(Theme.caption).foregroundStyle(open > 0 ? Theme.muted : Theme.ok).lineLimit(1)
        EpicProgress(done: issue.subIssuesDone, total: issue.subIssues).padding(.top, 4).padding(.bottom, 10)
        ForEach(rich, id: \.self) { i in
            IssueRowView(issue: model.boardIssues[i].summary, repo: model.repo, nested: true) { Navigator.shared.push(.issue(repo: model.repo, issue: model.boardIssues[i].raw)) }
                .padding(.bottom, 8)
        }
        if !rest.isEmpty {
            BoardBox {
                ForEach(Array(rest.enumerated()), id: \.offset) { k, i in
                    let link = model.subs[i]
                    LinkedRow(link: link, repo: model.repo, action: safeWebURL(link.url) || store.supports("issue") ? { model.openLink(link) } : nil)
                        .padding(.top, k > 0 ? 4 : 0)
                }
            }
        } else if rich.isEmpty {
            BoardBox {
                Text(open <= 0 ? "Every sub-issue is closed. The epic itself stays open until it is closed on GitHub."
                     : !model.boardRead && model.detail.isNull ? "Reading the board…" : "None of its open sub-issues is on this project’s board.")
                    .font(Theme.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        // Without the full read, the board is all there is: say what it cannot show.
        if model.detail.isNull && open > 0 && rich.count < open && model.boardRead {
            let missing = open - rich.count
            Text(verbatim: "\(missing) open sub-issue\(missing == 1 ? "" : "s") \(missing == 1 ? "is" : "are") in another repository or past the issues the board reads; GitHub lists them all.")
                .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
    }

    @ViewBuilder private var sessions: some View {
        if !model.runs.isEmpty {
            SectionTitle(title: "Sessions")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.runs, id: \.id) { run in
                    SessionRow(session: run, background: Theme.raise) { Navigator.shared.push(.conversation(id: run.id, session: run.raw)) }
                }
            }
            if let cost = runsCost(model.runs) {
                Text(verbatim: "\(formatCost(cost)) spent across \(model.runs.count) session\(model.runs.count == 1 ? "" : "s"), their workers included")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        }
    }
}

// MARK: - Sidebar

/// The sidebar, as GitHub's: what can be done here, then who and what it is filed under.
private struct IssueSidebar: View {
    @ObservedObject var model: IssueModel
    @ObservedObject private var store = Store.shared

    var body: some View {
        let issue = model.issue
        var items: [AnyView] = []
        if let a = actions { items.append(a) }
        items.append(AnyView(section("Assignees") {
            if issue.assignees.isEmpty { Text("No one").font(Theme.caption).foregroundStyle(Theme.muted) }
            ForEach(issue.assignees, id: \.self) { Text($0).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1) }
            if model.editable { editButton("Edit assignees ▾") { model.editAssignees() } }
        }))
        items.append(AnyView(section("Labels") {
            if issue.labels.isEmpty { Text("None yet").font(Theme.caption).foregroundStyle(Theme.muted) }
            else { LabelChips(labels: issue.labels, background: Theme.canvas) }
            if model.editable { editButton("Edit labels…") { model.editLabels() } }
        }))
        if !model.detail.isNull {
            let type = model.detail["type"].string
            items.append(AnyView(section("Type") {
                Text(type ?? "No type").font(type != nil ? Theme.footnote : Theme.caption).foregroundStyle(type != nil ? Theme.ink : Theme.muted).lineLimit(1)
            }))
            items.append(AnyView(projects))
        }
        items.append(AnyView(section("Milestone") {
            Text(issue.milestone ?? "No milestone").font(issue.milestone != nil ? Theme.footnote : Theme.caption)
                .foregroundStyle(issue.milestone != nil ? Theme.ink : Theme.muted).fixedSize(horizontal: false, vertical: true)
        }))
        items.append(AnyView(section("Relationships") {
            if let parent = issue.parent {
                Text("Parent issue").font(Theme.caption).foregroundStyle(Theme.muted)
                let linked = !parent.isForeign(model.repo) || safeWebURL(parent.url)
                LinkedRow(link: parent, repo: model.repo, action: linked ? { model.openLink(parent) } : nil)
            } else {
                Text("None yet").font(Theme.caption).foregroundStyle(Theme.muted)
            }
        }))
        items.append(AnyView(development))
        if let at = issue.updatedAt {
            items.append(AnyView(section("Updated") { Text(formatRelative(at)).font(Theme.footnote).foregroundStyle(Theme.ink) }))
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Spacer().frame(height: 14); BoardRule() }
                Spacer().frame(height: 14)
                item
            }
        }
    }

    /// `.discussion-sidebar-item`: a small heading over its contents.
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Theme.captionSemibold).foregroundStyle(Theme.muted).lineLimit(1).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 4) { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The edit button under the assignees or labels.
    private func editButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).dashButton(.bordered).disabled(model.editing).padding(.top, 4)
    }

    /// Start a session, and Close issue ▾, while it is open and the server takes them.
    private var actions: AnyView? {
        let start = store.supports("start_session"), close = store.supports("close_issue")
        guard !model.state.isClosed, start || close else { return nil }
        let issue = model.issue
        let answering = issueOpenPulls(issue) > 0
        return AnyView(section(model.busy ? "Actions · starting…" : "Actions") {
            if start && issue.isEpic {
                Text("An epic is worked by an orchestrator, one sub-issue at a time. Start it from the web dashboard, where its models are picked, or start one of its sub-issues here.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else if start {
                Button(model.busy ? "Starting…" : "Start a session on this issue") { model.start() }
                    .dashButton(.prominent, stretch: true).disabled(model.busy || model.uncertain)
                Text(model.runActive ? "A session is already working on this issue; it is listed under Sessions. A second one is a paid agent doing the same work."
                     : answering ? "A pull request is already answering this issue. A second session is a paid agent working on the same thing."
                     : "The session reads the issue, implements it on a branch of its own and opens a pull request closing it. It runs a paid agent on this project’s configured model.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            if close {
                Button(model.closing ? "Closing…" : "Close issue ▾") { model.close() }
                    .dashButton(.bordered, stretch: true).disabled(model.closing).padding(.top, start ? 8 : 0)
                Text(answering ? "Closes it on GitHub now. The pull requests answering it stay open; merging one later will not close it again."
                     : "Closes it on GitHub, as completed or as not planned, with a comment first if you write one.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        })
    }

    /// Each Projects v2 board it is on, with its Status and the rest of its fields.
    private var projects: some View {
        let list = model.detail["projects"].items
        return section("Projects") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, p in IssueProjectCard(project: p) }
            }
            if list.isEmpty {
                if let refused = model.detail["projectsError"].string {
                    Text("GitHub would not read its projects with the server’s token, which needs Projects: read. \(refused)")
                        .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("None yet").font(Theme.caption).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    /// GitHub's Development box: the pull requests linked to close it, merged and closed ones included.
    private var development: some View {
        let issue = model.issue
        let open = issueOpenPulls(issue)
        return section("Development") {
            if open > 0 {
                Text(open == 1 ? "Successfully merging this pull request may close this issue." : "Successfully merging one of these pull requests may close this issue.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
            } else if issue.pulls.isEmpty {
                Text("No pull request yet").font(Theme.caption).foregroundStyle(Theme.muted)
            }
            ForEach(Array(issue.pulls.enumerated()), id: \.offset) { _, link in
                let foreign = link.isForeign(model.repo) || !store.supports("pull")
                LinkedRow(link: link, repo: model.repo, action: !foreign || safeWebURL(link.url) ? { model.openPull(link) } : nil)
            }
        }
    }
}

/// One Projects v2 board an issue is on: its title, which opens it on GitHub, then its Status and the rest of its fields,
/// each name on the left and its value on the right.
private struct IssueProjectCard: View {
    var project: JSON
    var body: some View {
        let url = project["url"].string
        VStack(alignment: .leading, spacing: 2) {
            GlyphLabel(glyph: 0xE8FD, text: project["title"].string ?? "Project", font: Theme.footnoteSemibold)
                .contentShape(Rectangle())
                .onTapGesture { if safeWebURL(url) { openWebURL(url) } }
                .handCursor(safeWebURL(url))
                .padding(.bottom, 2)
            field("Status", project["status"].string ?? "No status")
            ForEach(Array(project["fields"].items.enumerated()), id: \.offset) { _, f in
                let v = f["value"]
                if let name = f["name"].string, let value = v.string ?? v.number.map({ String(format: "%g", $0) }) { field(name, value) }
            }
        }
    }
    /// The name takes about two fifths of a sidebar 240 to 320 points wide.
    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                .frame(width: 104, alignment: .leading)
            Text(value).font(Theme.footnote).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 20)
    }
}
