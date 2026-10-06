// One issue on a phone, as the Mac's issue page lays it out: the title with its state and who opened it, the body, an
// epic's sub-issues, the conversations started on it, what can be done, GitHub's sidebar facts as sections (assignees,
// labels, type, projects with their fields, milestone, parent, and under Development the pull requests linked to close
// it), and its timeline a page at a time. The issue is read in full (`issue`) with its timeline (`issue_timeline`); the
// board is still read beside it through the project's feed for the rows of the open sub-issues and pull requests, and the
// conversations from the project's. On a server without the issue's own read, the board's row is all the screen has. A
// session starts on it at a tap, its title, description, labels and assignees are edited on GitHub, and it is closed as
// completed or not planned, with a comment first.
import SwiftUI

/// The issue's own read and its timeline, kept where the Mac keeps them, so a screen opens on what it last showed; and
/// its edits.
@MainActor
final class IssuePageModel: ObservableObject {
    let repo: String
    let number: Int
    /// The issue in full: its body, type, projects, every sub-issue and linked pull request. Null until read.
    @Published private(set) var detail: JSON = .null
    @Published var detailError: String?
    /// Every sub-issue the full read lists, closed ones and other repositories' included.
    @Published private(set) var subs: [BoardLink] = []
    /// The timeline pages read so far, oldest first; nil until the first is in.
    @Published private(set) var events: [JSON]?
    /// The timeline's next page; 0 once it is all read.
    @Published private(set) var nextPage = 0
    @Published var timelineError: String?
    @Published private(set) var readingTimeline = false
    @Published private(set) var readingDetail = false
    /// Its title, description, labels or assignees are being saved. A failed edit has a notice of its own, so it leaves an
    /// uncertain start's notice up.
    @Published private(set) var editing = false
    @Published var editError: String?
    private var timelineRead = false
    /// The issue's updatedAt the timeline was read at, and the one it is being read at.
    private var timelineSeen: String?, timelineWant: String?
    private var detailGen = 0, timelineGen = 0

    init(repo: String, number: Int) {
        self.repo = repo; self.number = number
        let store = Store.shared
        if store.supports("issue"), let saved = store.cache.value(savedIssueKey(repo, number)) { show(saved["issue"]) }
        if store.supports("issue_timeline"), let saved = store.cache.value(timelineKey) { showTimeline(saved, first: true) }
    }

    private var timelineKey: String { "issue-timeline:\(repo)#\(number)" }
    /// The issue as its own read has it; nil until read.
    var summary: IssueSummary? { IssueSummary(detail) }

    private func show(_ value: JSON) {
        guard let fresh = IssueSummary(value), fresh.number == number else { return }
        detail = value
        subs = BoardLink.parseList(value["subIssues"]["items"])
    }
    private func showTimeline(_ result: JSON, first: Bool) {
        var all = first ? [] : (events ?? [])
        all.append(contentsOf: result["events"].items)
        events = all
        nextPage = result["nextPage"].int32 ?? 0
    }

    /// Reads the issue; its timeline again only when the issue has moved since, so the later pages read stay until then.
    func load() async throws {
        guard Store.shared.supports("issue"), !readingDetail else { return }
        detailGen += 1
        let gen = detailGen
        readingDetail = true
        defer { if gen == detailGen { readingDetail = false } }
        do {
            let v = try await Store.shared.call("issue", ["issue": JSON(number), "repo": .string(repo)])
            guard gen == detailGen else { return }
            show(v["issue"])
            detailError = nil
            Store.shared.cache.store(v, savedIssueKey(repo, number))
            let updated = detail["updatedAt"].string
            if !timelineRead || updated == nil || updated != timelineSeen { timelineWant = updated; loadTimeline(page: 1) }
        } catch {
            if gen == detailGen, let said = failure(error) { detailError = said }
            throw error
        }
    }
    private func loadTimeline(page: Int) {
        guard Store.shared.supports("issue_timeline") else { return }
        timelineGen += 1
        let gen = timelineGen
        readingTimeline = true
        Task {
            do {
                let v = try await Store.shared.call("issue_timeline", ["issue": JSON(number), "repo": .string(repo), "page": JSON(page)])
                guard gen == timelineGen else { return }
                readingTimeline = false
                showTimeline(v, first: page <= 1)
                if page <= 1 {
                    timelineSeen = timelineWant
                    Store.shared.cache.store(v, timelineKey)
                }
                timelineRead = true
                timelineError = nil
            } catch {
                guard gen == timelineGen else { return }
                readingTimeline = false
                if let said = failure(error) { timelineError = said }
            }
        }
    }
    func moreActivity() { if nextPage > 0 && !readingTimeline { loadTimeline(page: nextPage) } }
    /// Pulling down reads the issue and its timeline again, whatever was in flight.
    func reset() {
        detailGen += 1; readingDetail = false
        timelineSeen = nil
        editError = nil
    }

    /// Sends `fields` as an edit of this issue; true once GitHub took it. The title and description show as saved at once;
    /// the read already under way is dropped, since it may have been made before the edit.
    func edit(_ fields: JSON) async -> Bool {
        guard !editing else { return false }
        editing = true; editError = nil
        defer { editing = false }
        var args = fields
        args["issue"] = JSON(number); args["repo"] = .string(repo)
        do {
            let v = try await Store.shared.call("update_issue", args)
            if !detail.isNull {
                if let title = v["issue"]["title"].string { detail["title"] = .string(title) }
                if let body = v["issue"]["body"].string, args["body"].string != nil { detail["body"] = .string(body) }
            }
            detailGen += 1; readingDetail = false
            return true
        } catch {
            // An edit sets what it names, so trying again is safe.
            if let said = failure(error) { editError = said }
            return false
        }
    }
}

struct IssueScreen: View {
    let repo: String
    let issue: JSON

    @EnvironmentObject private var store: Store
    @ObservedObject private var feed: ProjectFeed
    @StateObject private var model: IssuePageModel
    @Environment(\.navigate) private var navigate
    /// The board was read while on show, after which an issue missing from it has left it.
    @State private var boardRead = false
    @State private var loadError: String?
    @State private var busy = false
    @State private var uncertain = false
    @State private var writeError: String?
    @State private var closing = false
    @State private var closeReason: CloseReason?
    @State private var commenting: CloseReason?
    @State private var comment: String?
    /// The close the comment sheet leads to, asked once the sheet is down.
    @State private var pendingClose: CloseReason?
    /// This screen closed it, and how; the board no longer lists it.
    @State private var closedReason: String?
    @State private var editPrompt: ItemEdit?

    fileprivate enum CloseReason: String, Identifiable {
        case completed, notPlanned = "not_planned"
        var id: String { rawValue }
        var words: String { self == .completed ? "completed" : "not planned" }
    }

    init(repo: String, issue: JSON) {
        self.repo = repo; self.issue = issue
        feed = Store.shared.feed(repo)
        _model = StateObject(wrappedValue: IssuePageModel(repo: repo, number: issue["number"].truncatedInt ?? 0))
    }

    private var number: Int { issue["number"].truncatedInt ?? 0 }
    private var boardIssues: [(summary: IssueSummary, raw: JSON)] { feed.board["issues"].items.compactMap { j in IssueSummary(j).map { ($0, j) } } }
    private var boardPulls: [PullSummary] { PullSummary.parseList(feed.board["pulls"]) }
    /// The issue's own read, else the board's row when it lists it, else what the screen was opened with.
    private var row: IssueSummary {
        model.summary ?? boardIssues.first { $0.summary.number == number }?.summary ?? IssueSummary(issue) ?? IssueSummary(["number": JSON(max(number, 1))])!
    }
    /// The board was read and this issue is not on it; a board GitHub refused the issues of says nothing about it.
    private var gone: Bool {
        boardRead && closedReason == nil && !feed.board["issuesError"].isSet && !boardIssues.contains { $0.summary.number == number }
    }
    private var state: IssuePageState { IssuePageState(detail: model.detail, closedHere: closedReason != nil, closedReason: closedReason, gone: gone) }
    private var runs: [Session] { feed.sessions.filter { issueRunMatches($0, issue: row, repo: repo) } }
    private var runActive: Bool { runs.contains { $0.isActive } }
    /// Edits go to GitHub while the server takes them and this screen has not closed it.
    private var editable: Bool { store.supports("update_issue") && closedReason == nil }

    var body: some View {
        let issue = row
        List {
            notices
            header(issue)
            description(issue)
            if issue.isEpic { subIssues(issue) }
            sessions
            actions(issue)
            facts(issue)
            IssueActivity(model: model, repo: repo, open: openEvent)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle(Text(verbatim: "#\(issue.number)")).navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(issue) }
        .refreshable {
            uncertain = false; writeError = nil
            model.reset()
            async let sessions: Void? = store.supports("sessions") ? try? feed.loadSessions(fresh: true) : nil
            _ = await reading { try await load(fresh: true) }
            _ = await sessions
        }
        .task {
            await poll(every: ProjectFeed.boardEvery) {
                if model.editing || closing { return nil }
                return await reading { try await load() }
            }
        }
        .task {
            guard store.supports("sessions") else { return }
            await poll(every: ProjectFeed.sessionsEvery) { await reading { try await feed.loadSessions() } }
        }
        .alert(closeReason.map { "Close issue #\(issue.number) as \($0.words)?" } ?? "",
               isPresented: Binding(get: { closeReason != nil }, set: { if !$0 { closeReason = nil } }), presenting: closeReason) { reason in
            Button("Close issue", role: .destructive) { Task { await close(reason) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            if let why = closeNote(issue) { Text(why) }
        }
        .sheet(item: $commenting, onDismiss: {
            if let p = pendingClose { pendingClose = nil; closeReason = p }
        }) { reason in
            CloseCommentSheet(number: issue.number, reason: reason.words) { text in
                comment = text.cTrimmed.isEmpty ? nil : text
                pendingClose = reason
            }
            .presentationDetents([.medium, .large])
        }
        .itemEdits($editPrompt, target: ItemEditTarget(what: "issue", number: issue.number, title: issue.title, body: model.detail["body"].string,
                                                       labels: issue.labels, assignees: issue.assignees)) { fields in edit(fields) }
    }

    /// The board for the rows of the open sub-issues and pull requests, and the issue itself beside it.
    private func load(fresh: Bool = false) async throws {
        let detail = Task { await reading { try await model.load() } }
        var failed: Error?
        if store.supports("pulls") {
            do {
                try await feed.loadBoard(fresh: fresh)
                boardRead = true
                loadError = nil
            } catch {
                if let said = failure(error) { loadError = said }
                failed = error
            }
        }
        let detailFailed = await detail.value
        if let e = failed ?? detailFailed { throw e }
    }

    @ToolbarContentBuilder private func toolbar(_ issue: IssueSummary) -> some ToolbarContent {
        if editable || safeWebURL(issue.url) {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if editable {
                        Button { editPrompt = .details } label: { Label("Edit title and description…", systemImage: "pencil") }
                            .disabled(model.editing || model.detail["body"].string == nil)
                    }
                    if safeWebURL(issue.url) {
                        Button { boardOpenWeb(issue.url) } label: { Label("Open on GitHub", systemImage: "safari") }
                        Button { Pasteboard.copy(issue.url ?? "") } label: { Label("Copy link", systemImage: "link") }
                    }
                } label: {
                    if model.editing { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                }
                .accessibilityLabel("More")
            }
        }
    }

    // MARK: Top

    @ViewBuilder private var notices: some View {
        if let e = writeError {
            Section {
                ErrorNotice(message: e)
                if uncertain {
                    Text("The request may have completed. Check the project’s conversations before starting another agent.").font(.footnote).foregroundStyle(.secondary)
                    Button("I have checked") { uncertain = false; writeError = nil }.font(.callout)
                }
            }
            .listRowBackground(Theme.row)
        }
        if let e = model.editError { Section { ErrorNotice(message: e) }.listRowBackground(Theme.row) }
        if let e = model.detailError { Section { ErrorNotice(message: e) }.listRowBackground(Theme.row) }
        if let e = loadError, e != model.detailError { Section { ErrorNotice(message: e) }.listRowBackground(Theme.row) }
        if let reason = closedReason {
            Section {
                Label(reason == "not_planned" ? "Closed as not planned" : "Closed as completed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text("It has left the board. Reopen it on GitHub if it was closed by mistake.").font(.footnote).foregroundStyle(.secondary)
            }
            .listRowBackground(Theme.row)
        } else if gone && model.detail.isNull {
            Section {
                Label("This issue is no longer on the board", systemImage: "info.circle")
                Text("It was closed, or it is past the most recently updated issues the server reads. What is shown is how it was last seen.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .listRowBackground(Theme.row)
        }
    }

    /// The title and number, then the state pill and GitHub's sentence: who opened it, when, and its comments.
    private func header(_ issue: IssueSummary) -> some View {
        let state = self.state
        let color: Color = state == .open ? Theme.success : state == .closed ? Theme.accent : .secondary
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                (Text(issue.title) + Text(verbatim: "  #\(issue.number)").foregroundStyle(.secondary))
                    .font(.title3.weight(.semibold)).textSelection(.enabled)
                BoardFlowLayout(spacing: 4) {
                    BoardBadge(text: state.text.asciiCapitalized, systemImage: state.isClosed ? "checkmark.circle.fill" : "smallcircle.filled.circle", color: color)
                        .padding(.trailing, 2)
                    if let author = issue.author { Text("@\(author)").font(.footnote.weight(.semibold)) }
                    if let at = issue.createdAt {
                        Text("\(issue.author != nil ? "opened this issue" : "Opened") \(formatRelative(at))").font(.footnote).foregroundStyle(.secondary)
                    }
                    if state.isClosed, let at = boardDateParse(model.detail["closedAt"].string) {
                        Text("· closed \(formatRelative(at))").font(.footnote).foregroundStyle(.secondary)
                    }
                    if issue.comments > 0 {
                        Text("· \(issue.comments) comment\(issue.comments == 1 ? "" : "s")").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Theme.row)
    }

    /// The opening comment: the issue's body as GitHub shows it. Without the issue's own read, what the board's row carries.
    @ViewBuilder private func description(_ issue: IssueSummary) -> some View {
        let body = store.supports("issue") ? model.detail["body"].string : self.issue["body"].string
        if store.supports("issue") || body != nil {
            Section {
                if let body {
                    let text = visibleMarkdown(body)
                    if text.isEmpty { Text("No description provided.").italic().foregroundStyle(.secondary) }
                    else { MarkdownText(text).font(.callout) }
                } else if model.detailError != nil {
                    Text("The description could not be read.").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) { ProgressView(); Text("Loading the description…").foregroundStyle(.secondary) }
                }
            } header: {
                Text(issue.author.map { "@\($0)" } ?? "Description")
            }
            .listRowBackground(Theme.row)
        }
    }

    /// An epic's sub-issues: the open ones on the board drawn as the board draws them, every other one the full read
    /// lists as a link, closed ones included.
    @ViewBuilder private func subIssues(_ issue: IssueSummary) -> some View {
        let all = boardIssues
        let rich = issueOpenSubIssues(all.map(\.summary), epic: issue.number, repo: repo)
        let rest = model.subs.filter { s in !rich.contains { !s.isForeign(repo) && all[$0].summary.number == s.number } }
        let open = issue.subIssues - issue.subIssuesDone
        Section {
            HStack {
                Text("\(issue.subIssuesDone) of \(issue.subIssues) completed").font(.callout).foregroundStyle(open > 0 ? Color.secondary : Theme.success)
                Spacer()
                BoardEpicProgress(done: issue.subIssuesDone, total: issue.subIssues)
            }
            ForEach(rich, id: \.self) { i in
                DestinationLink(destination: .issue(repo: repo, issue: all[i].raw)) { BoardIssueRow(issue: all[i].summary, repo: repo, nested: true) }
            }
            ForEach(Array(rest.enumerated()), id: \.offset) { _, link in linkRow(link) }
            if rich.isEmpty && rest.isEmpty {
                Text(open <= 0 ? "Every sub-issue is closed. The epic itself stays open until it is closed on GitHub."
                     : !feed.boardLoaded && model.detail.isNull ? "Reading the board…" : "None of its open sub-issues is on this project’s board.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Sub-issues")
        } footer: {
            // Without the full read, the board is all there is: say what it cannot show.
            if model.detail.isNull && open > 0 && rich.count < open && feed.boardLoaded {
                let missing = open - rich.count
                Text("\(missing) open sub-issue\(missing == 1 ? "" : "s") \(missing == 1 ? "is" : "are") in another repository or past the issues the board reads; GitHub lists them all.")
            }
        }
        .listRowBackground(Theme.row)
    }

    @ViewBuilder private var sessions: some View {
        let runs = self.runs
        if !runs.isEmpty {
            Section {
                ForEach(runs, id: \.id) { run in
                    DestinationLink(destination: .conversation(id: run.id, session: run.raw)) { BoardSessionRow(session: run) }
                }
            } header: {
                Text("Sessions")
            } footer: {
                if let cost = runsCost(runs) {
                    Text("\(formatCost(cost)) spent across \(runs.count) session\(runs.count == 1 ? "" : "s"), their workers included")
                }
            }
            .listRowBackground(Theme.row)
        }
    }

    /// Start a session, and Close issue, while it is open and the server takes them. The screen already says the session is
    /// paid and whether one is at work on it, so it starts at a tap.
    @ViewBuilder private func actions(_ issue: IssueSummary) -> some View {
        let answering = issueOpenPulls(issue) > 0
        if store.supports("start_session") && !state.isClosed {
            Section {
                if issue.isEpic {
                    Text("An epic is worked by an orchestrator, one sub-issue at a time. It is not started from this app; start one of its sub-issues here.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button { Task { await start() } } label: {
                        HStack {
                            Label(busy ? "Starting…" : "Start a session on this issue", systemImage: "play.fill").fontWeight(.semibold)
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || uncertain)
                }
            } footer: {
                if !issue.isEpic {
                    Text(runActive ? "A session is already working on this issue; it is listed under Sessions. A second one is a paid agent doing the same work."
                         : answering ? "A pull request is already answering this issue. A second session is a paid agent working on the same thing."
                         : "The session reads the issue, implements it on a branch of its own and opens a pull request closing it. It runs a paid agent on this project’s configured model.")
                }
            }
            .listRowBackground(Theme.row)
        }
        if store.supports("close_issue") && !state.isClosed {
            Section {
                Menu {
                    Button("Close as completed", systemImage: "checkmark.circle") { comment = nil; closeReason = .completed }
                    Button("Close as not planned", systemImage: "nosign") { comment = nil; closeReason = .notPlanned }
                    Section {
                        Button("Completed, with a comment…", systemImage: "text.bubble") { commenting = .completed }
                        Button("Not planned, with a comment…", systemImage: "text.bubble") { commenting = .notPlanned }
                    }
                } label: {
                    HStack {
                        Label("Close issue", systemImage: "xmark.circle").foregroundStyle(Theme.danger)
                        if closing { Spacer(); ProgressView() }
                    }
                }
                .disabled(closing)
            } footer: {
                Text(answering ? "Closes it on GitHub now. The pull requests answering it stay open; merging one later will not close it again."
                     : "Closes it on GitHub, as completed or as not planned, with a comment first if you write one.")
            }
            .listRowBackground(Theme.row)
        }
    }

    // MARK: Sidebar facts

    /// GitHub's sidebar as sections: who and what it is filed under, then where it is going.
    @ViewBuilder private func facts(_ issue: IssueSummary) -> some View {
        Section {
            ForEach(issue.assignees, id: \.self) { Text("@\($0)") }
            if issue.assignees.isEmpty { Text("No one").foregroundStyle(.secondary) }
            if editable {
                Menu {
                    AssigneesMenuItems(assignees: issue.assignees, edit: $editPrompt) { edit($0) }
                } label: {
                    Label("Edit assignees", systemImage: "person.badge.plus")
                }
                .disabled(model.editing)
            }
        } header: {
            Text("Assignees")
        }
        .listRowBackground(Theme.row)
        Section("Labels") {
            if issue.labels.isEmpty { Text("None yet").foregroundStyle(.secondary) }
            else { BoardLabelChips(labels: issue.labels).padding(.vertical, 2) }
            if editable {
                Button { editPrompt = .labels } label: { Label("Edit labels…", systemImage: "tag") }.disabled(model.editing)
            }
        }
        .listRowBackground(Theme.row)
        if !model.detail.isNull {
            let type = model.detail["type"].string
            Section("Type") { Text(type ?? "No type").foregroundStyle(type != nil ? .primary : .secondary) }.listRowBackground(Theme.row)
            projects
        }
        Section("Milestone") {
            Text(issue.milestone ?? "No milestone").foregroundStyle(issue.milestone != nil ? .primary : .secondary)
        }
        .listRowBackground(Theme.row)
        Section {
            if let parent = issue.parent { linkRow(parent) } else { Text("None yet").foregroundStyle(.secondary) }
        } header: {
            Text("Relationships")
        } footer: {
            if issue.parent != nil { Text("Its parent issue.") }
        }
        .listRowBackground(Theme.row)
        development(issue)
        if let at = issue.updatedAt {
            Section("Updated") { Text("\(formatRelative(at)) · \(formatDateAbbrev(at))") }.listRowBackground(Theme.row)
        }
    }

    /// Each Projects v2 board it is on, with its Status and the rest of its fields; or why there are none.
    @ViewBuilder private var projects: some View {
        let list = model.detail["projects"].items
        ForEach(Array(list.enumerated()), id: \.offset) { _, p in IssueProjectSection(project: p) }
        if list.isEmpty {
            Section("Projects") {
                if let refused = model.detail["projectsError"].string {
                    Text("GitHub would not read its projects with the server’s token, which needs Projects: read.").font(.footnote).foregroundStyle(.secondary)
                    ErrorNotice(message: refused)
                } else {
                    Text("None yet").foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Theme.row)
        }
    }

    /// GitHub's Development box: the pull requests linked to close it, merged and closed ones included. One on the board is
    /// drawn as the board draws it; the rest as links, which open on the pull request's screen when it is this project's.
    @ViewBuilder private func development(_ issue: IssueSummary) -> some View {
        let rows = boardPulls
        let open = issueOpenPulls(issue)
        Section {
            ForEach(Array(issue.pulls.enumerated()), id: \.offset) { _, link in
                if !link.isForeign(repo), store.supports("pull"), let pull = pullsFind(rows, link.number) {
                    let stack = StackPosition(pull.raw["stack"], stacks: feed.board["stacks"])
                    DestinationLink(destination: .pull(repo: repo, number: pull.number, stack: stack?.json, summary: pull.raw)) {
                        BoardPullRow(pull: pull, stack: stack, repo: repo,
                                     activeRuns: feed.sessions.filter { $0.pullNumber == pull.number && $0.isActive }.count, showsIssues: false)
                    }
                } else if !link.isForeign(repo), store.supports("pull") {
                    DestinationLink(destination: .pull(repo: repo, number: link.number, stack: nil, summary: nil)) { BoardLinkedRow(link: link, repo: repo) }
                } else if safeWebURL(link.url) {
                    Button { boardOpenWeb(link.url) } label: { BoardLinkedRow(link: link, repo: repo) }.foregroundStyle(.primary)
                } else {
                    BoardLinkedRow(link: link, repo: repo)
                }
            }
            if issue.pulls.isEmpty { Text("No pull request yet").foregroundStyle(.secondary) }
        } header: {
            Text("Development")
        } footer: {
            if open > 0 {
                Text(open == 1 ? "Successfully merging this pull request may close this issue." : "Successfully merging one of these pull requests may close this issue.")
            }
        }
        .listRowBackground(Theme.row)
    }

    /// An issue named on the page: this repository's opens here, any other on GitHub.
    @ViewBuilder private func linkRow(_ link: BoardLink) -> some View {
        if let d = issueDestination(link) {
            DestinationLink(destination: d) { BoardLinkedRow(link: link, repo: repo) }
        } else if safeWebURL(link.url) {
            Button { boardOpenWeb(link.url) } label: { BoardLinkedRow(link: link, repo: repo) }.foregroundStyle(.primary)
        } else {
            BoardLinkedRow(link: link, repo: repo)
        }
    }

    // MARK: Opening

    /// Where an issue of this repository opens: from its board row when it has one, else bare, as the issue's own read
    /// fills the rest in.
    private func issueDestination(_ link: BoardLink) -> Destination? {
        guard !link.isForeign(repo) else { return nil }
        if let row = boardIssues.first(where: { $0.summary.number == link.number }) { return .issue(repo: repo, issue: row.raw) }
        guard store.supports("issue") else { return nil }
        var bare: JSON = ["number": JSON(link.number), "title": .string(link.title)]
        if let url = link.url { bare["url"] = .string(url) }
        return .issue(repo: repo, issue: bare)
    }
    /// Where tapping an event goes: a comment's place on GitHub, the issue, pull request or commit it points to.
    private func openEvent(_ e: JSON) {
        if e["kind"].string == "commented" { boardOpenWeb(e["url"].string); return }
        let ref = e["source"].isSet ? e["source"] : e["issue"]
        if let link = BoardLink(ref) {
            if ref["kind"].string == "pull" {
                if link.isForeign(repo) || !store.supports("pull") { boardOpenWeb(link.url) }
                else { navigate(.pull(repo: repo, number: link.number, stack: nil, summary: pullsFind(boardPulls, link.number)?.raw)) }
            } else if let d = issueDestination(link) {
                navigate(d)
            } else {
                boardOpenWeb(link.url)
            }
            return
        }
        boardOpenWeb(e["commit"]["url"].string)
    }

    // MARK: Writes

    private func start() async {
        guard !busy, !uncertain else { return }
        busy = true
        defer { busy = false }
        let args: JSON = ["repo": .string(repo), "prompt": .string(issuePrompt(row, repo: repo)), "activity": "issue"]
        do {
            let v = try await store.call("start_session", args)
            writeError = nil
            if store.supports("sessions") { try? await feed.loadSessions(fresh: true) }
            if let s = Session(v["session"]) { navigate(.conversation(id: s.id, session: s.raw)) }
        } catch {
            guard let said = failure(error) else { return }
            writeError = said
            if (error as? APIError)?.isRefusal != true { uncertain = true }
        }
    }

    /// An edit, then the issue and the board read again for what it changed.
    private func edit(_ fields: JSON) {
        Task { if await model.edit(fields) { _ = await reading { try await load(fresh: true) } } }
    }

    /// What stays open once it is closed, and that a comment goes first.
    private func closeNote(_ issue: IssueSummary) -> String? {
        let open = issue.subIssues - issue.subIssuesDone
        var why = ""
        if open > 0 { why += "\(open) of its sub-issues \(open == 1 ? "is" : "are") still open and stay\(open == 1 ? "s" : "") open. " }
        if runActive { why += "A session is still working on it; closing does not stop it. " }
        if comment != nil { why += "Your comment is posted first." }
        return why.isEmpty ? nil : why.cTrimmed
    }

    private func close(_ reason: CloseReason) async {
        guard !closing, closedReason == nil else { return }
        closing = true; writeError = nil
        defer { closing = false }
        var args: JSON = ["issue": JSON(number), "repo": .string(repo), "reason": .string(reason.rawValue)]
        if let comment { args["comment"] = .string(comment) }
        do {
            let v = try await store.call("close_issue", args)
            closedReason = v["issue"]["stateReason"].string ?? reason.rawValue
            comment = nil
            // The board drops it; reading it again keeps the epic's counts and its siblings true.
            model.reset()
            _ = await reading { try await load(fresh: true) }
        } catch {
            // Closing twice only restates the reason, so trying again is safe.
            if let said = failure(error) { writeError = said }
        }
    }
}

// MARK: - Activity

/// The issue's timeline (the Mac's IssueActivity): comments as GitHub's boxes, every other event a line beside its symbol,
/// worded by timelineEventWords; a page of 100 at a time, with Show more activity for the next.
private struct IssueActivity: View {
    @ObservedObject var model: IssuePageModel
    let repo: String
    let open: (JSON) -> Void
    @EnvironmentObject private var store: Store

    var body: some View {
        // The timeline is read once the issue is; when that read failed, there is none coming.
        if store.supports("issue_timeline") && !(model.events == nil && !model.readingTimeline && model.detailError != nil) {
            Section("Activity") {
                if let e = model.timelineError { ErrorNotice(message: e) }
                if let events = model.events {
                    let shown = events.indices.filter { events[$0]["kind"].string == "commented" || timelineEventWords(events[$0], repo: repo) != nil }
                    ForEach(shown, id: \.self) { i in
                        let e = events[i]
                        if e["kind"].string == "commented" { comment(e) }
                        else if let words = timelineEventWords(e, repo: repo) { event(e, words) }
                    }
                    if shown.isEmpty { Text("No activity yet").foregroundStyle(.secondary) }
                    if model.nextPage > 0 {
                        Button { model.moreActivity() } label: {
                            HStack {
                                Label(model.readingTimeline ? "Loading…" : "Show more activity", systemImage: "ellipsis.circle")
                                if model.readingTimeline { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(model.readingTimeline)
                    }
                } else if model.timelineError == nil {
                    HStack(spacing: 8) { ProgressView(); Text("Loading the timeline…").foregroundStyle(.secondary) }
                }
            }
            .listRowBackground(Theme.row)
        }
    }

    private func when(_ e: JSON) -> String? { boardDateParse(e["createdAt"].string).map { formatRelative($0) } }

    private func comment(_ e: JSON) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
                Text(e["actor"].string ?? "ghost").fontWeight(.semibold)
                Text("commented" + (when(e).map { " · \($0)" } ?? "")).foregroundStyle(.secondary)
            }
            .font(.caption).lineLimit(1)
            let t = visibleMarkdown(e["body"].string ?? "")
            if t.isEmpty { Text("No description provided.").italic().foregroundStyle(.secondary) } else { MarkdownText(t).font(.callout) }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if safeWebURL(e["url"].string) {
                Button { boardOpenWeb(e["url"].string) } label: { Label("Open on GitHub", systemImage: "safari") }
                Button { Pasteboard.copy(e["url"].string ?? "") } label: { Label("Copy link", systemImage: "link") }
            }
        }
    }

    @ViewBuilder private func event(_ e: JSON, _ words: TimelineWords) -> some View {
        let tone: Color = words.tone == .accent ? Theme.accent : words.tone == .ok ? Theme.success : .secondary
        let line = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Self.symbol(words.glyph)).font(.caption).foregroundStyle(tone).frame(width: 18)
            sentence(e, words).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
        }
        if timelineEventHasTarget(e) {
            Button { open(e) } label: { line }.foregroundStyle(.primary)
        } else {
            line
        }
    }

    /// The actor, then GitHub's words with each run in its style, then when.
    private func sentence(_ e: JSON, _ words: TimelineWords) -> Text {
        var t = Text((e["actor"].string ?? "ghost") + " ").fontWeight(.semibold)
        for p in words.parts { t = t + run(p) }
        if let at = when(e) { t = t + Text(at).foregroundStyle(.secondary) }
        return t
    }
    private func run(_ p: TimelinePart) -> Text {
        switch p.style {
        case .strong, .quotedStrong: return Text(p.text).fontWeight(.semibold)
        case .muted, .quoted: return Text(p.text).foregroundStyle(.secondary)
        case .reference: return Text(p.text).fontWeight(.semibold).foregroundStyle(Theme.accent)
        case .ink: return Text(p.text)
        // A chip on the Mac; a phone's line of text keeps it in the accent, monospaced.
        case .label, .sha: return Text(p.text + " ").font(.caption.monospaced()).foregroundStyle(Theme.accent)
        }
    }

    /// The SF Symbol for an event's glyph, a Segoe Fluent Icons code point as the core names it.
    private static func symbol(_ glyph: UInt32) -> String {
        switch glyph {
        case 0xE77B: return "person"
        case 0xE7C1: return "flag"
        case 0xE70F: return "pencil"
        case 0xE711: return "nosign"
        case 0xE73E: return "checkmark.circle.fill"
        case 0xE72C: return "arrow.uturn.backward.circle"
        case 0xE71B: return "link"
        case 0xE8EE: return "point.3.connected.trianglepath.dotted"
        case 0xE8FD: return "rectangle.split.3x1"
        default: return "tag"
        }
    }
}

/// The comment posted on an issue before it is closed.
private struct CloseCommentSheet: View {
    let number: Int
    let reason: String
    let next: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Why it is being closed", text: $text, axis: .vertical).lineLimit(5...14).focused($focused)
                } footer: {
                    Text(verbatim: "Posted on #\(number) before it is closed as \(reason). You confirm the close next.")
                }
                .listRowBackground(Theme.row)
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Comment").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") { dismiss(); next(text) }.bold().disabled(text.cTrimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}
