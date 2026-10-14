// What the pull request screen reads and writes (the Mac's PullModel): the pull request itself, its description, findings
// and conversation, its board row and conversations through the project's feed, the merge, the edits of its title,
// description, labels and assignees, Update branch, and the Run tab that serves it in an embedded browser.
import Combine
import SwiftUI

/// The parts of the pull request screen, as the section picker lists them.
enum PullSection: String, CaseIterable, Identifiable {
    case description, files, reviews, issues, projects, findings, conversations, run
    var id: String { rawValue }
    var title: String {
        switch self {
        case .description: return "Description"
        case .files: return "Files"
        case .reviews: return "Reviews"
        case .issues: return "Issues"
        case .projects: return "Projects"
        case .findings: return "Findings"
        case .conversations: return "Conversations"
        case .run: return "Run"
        }
    }
    var symbol: String {
        switch self {
        case .description: return "doc.text"
        case .files: return "doc.on.doc"
        case .reviews: return "text.bubble"
        case .issues: return "link"
        case .projects: return "rectangle.split.3x1"
        case .findings: return "flag"
        case .conversations: return "bubble.left.and.bubble.right"
        case .run: return "play.fill"
        }
    }
}

/// What stands in the way of a merge, asked about before it goes ahead.
struct MergeQuestion: Identifiable {
    var base: String
    var notes: [String]
    var id: String { base + notes.joined() }
}

@MainActor
final class PullScreenModel: ObservableObject {
    let repo: String
    let number: Int
    let summary: PullSummary?
    let feed: ProjectFeed

    @Published var section = PullSection.description
    /// The board's rows, and its place in a stack with the branches of the rows it is built on.
    @Published private(set) var rows: [PullSummary] = []
    @Published private(set) var stack: StackPosition?
    /// True once the board was read while on show: a pull request it no longer lists has been merged or closed.
    @Published private(set) var rowRead = false
    private var savedRow: PullSummary?
    @Published private(set) var pr: JSON = .null
    @Published private(set) var descriptionBody: String?
    @Published private(set) var descriptionAuthor: String?
    @Published private(set) var bodyRead = false
    private var readingBody = false
    @Published private(set) var findings: JSON = []
    @Published private(set) var runs: [Session] = []
    @Published var error: String?
    @Published var findingsError: String?
    @Published var mergeError: String?
    @Published private(set) var merging = false
    @Published var mergeQuestion: MergeQuestion?
    /// Its title, description, labels or assignees are being saved, and why the last edit failed.
    @Published private(set) var editing = false
    @Published var editError: String?
    /// Update branch is under way, and what GitHub was asked to do once it took the request.
    @Published private(set) var updatingBranch = false
    @Published var branchNote: String?
    @Published private(set) var deciding: String?
    @Published private(set) var readingPull = false
    @Published private(set) var deletingRun: String?
    @Published var runError: String?
    @Published private(set) var comments = Array(repeating: ConvList(), count: ConvFeed.allCases.count)
    private var pullGen = 0
    private var commentTasks: [Task<Void, Never>?] = Array(repeating: nil, count: ConvFeed.allCases.count)
    private var sinks: [AnyCancellable] = []
    /// The projects of the issues it closes, for the Projects section (IssueProjects.swift).
    lazy var issueProjects = IssueProjectsReader(repo: repo, linked: { [weak self] in self?.linkedIssues() ?? [] },
                                                 changed: { [weak self] in self?.objectWillChange.send() })

    // The Run tab: opening it serves the pull request (▶ Run) and shows it in an embedded browser. Core's `RunServe` holds
    // which session serves it, at what address and with which profile; the model makes the calls and runs the browser.
    @Published private(set) var serve = RunServe()
    var runURL: String? { serve.url }
    var runSession: String? { serve.session }
    var runProfile: String? { serve.profile }
    var runAsked: String? { serve.asked }
    var serveError: String? { serve.error }
    var runBusy: Bool { serve.busy }
    /// Waits for the conversations, in case a Run already serves this pull request.
    private var runPending = false
    /// The project's run profiles, the default first.
    @Published private(set) var profiles: [String] = []
    private var profilesRead = false, readingProfiles = false
    /// The log of the Run being prepared, from its session's transcript: `logSession` is the session followed.
    @Published private(set) var logSession: String?
    @Published private(set) var log = RunLog()
    private var readingLog = false
    @Published private(set) var browser: RunBrowser?
    private var browserSink: AnyCancellable?
    /// The Cloudflare Access service token the browser sends to preview hosts, read once before it first opens.
    private var access: RunWebAccess?
    private var accessRead = false, readingAccess = false
    private var shown = false

    init(repo: String, number: Int, stack: StackPosition?, summary: PullSummary?) {
        self.repo = repo; self.number = number; self.stack = stack; self.summary = summary
        feed = Store.shared.feed(repo)
        profiles = runProfilesParse(ProjectsModel.shared.raw, repo: repo)
        restore()
        take(feed.board)
        runs = feed.sessions.filter { $0.pullNumber == number }
        // The feed is shared with the board: what either reads shows on both.
        sinks.append(feed.$board.dropFirst().sink { [weak self] board in MainActor.assumeIsolated { self?.take(board) } })
        sinks.append(feed.$sessions.dropFirst().sink { [weak self] list in
            MainActor.assumeIsolated {
                guard let self else { return }
                let mine = list.filter { $0.pullNumber == self.number }
                if mine != self.runs { self.runs = mine }
            }
        })
    }

    private func take(_ board: JSON) {
        guard board.isObject else { return }
        rows = PullSummary.parseList(board["pulls"])
        if let r = pullsFind(rows, number) {
            var s = StackPosition(r.raw["stack"], stacks: board["stacks"])
            s?.fillBranches(rows)
            stack = s
        }
    }

    var boardRow: PullSummary? {
        let listed = pullsFind(rows, number)
        return rowRead ? listed : (listed ?? savedRow ?? summary)
    }
    /// What the pull request is and what may be done with it, as Core decides it.
    var record: PullRecord { PullRecord(number: number, pr: pr, row: boardRow, descriptionAuthor: descriptionAuthor) }
    var isOpen: Bool { record.isOpen }
    var draft: Bool { record.draft }
    var author: String? { record.author }
    var commitCount: Int { record.commitCount }
    var title: String { record.title }
    var url: String? { record.url }
    var head: String? { record.head }
    var base: String? { record.base }
    var closes: [BoardLink] { record.closes }

    /// The errands on offer: those the server lists for an open pull request with a branch. ▶ Run is the Run tab here.
    func actions(_ catalog: JSON) -> [BoardAction] {
        let record = record
        guard record.takesErrands else { return [] }
        return record.errands(boardErrands(catalog: catalog, pull: boardRow, failedChecks: record.failedChecks))
    }

    // MARK: Saving

    private var key: String { PullSnapshot.key(repo: repo, number: number) }
    private func save() {
        let snapshot = PullSnapshot(pr: pr, findings: findings, row: boardRow, stack: stack, body: descriptionBody, bodyAuthor: descriptionAuthor)
        if let saved = snapshot.json { Store.shared.cache.store(saved, key) }
    }
    private func restore() {
        guard let saved = PullSnapshot(Store.shared.cache.value(key)) else { return }
        pr = saved.pr
        findings = saved.findings
        descriptionBody = saved.body
        descriptionAuthor = saved.bodyAuthor
        savedRow = saved.row
        if stack == nil { stack = saved.stack }
    }

    // MARK: Reading

    private var args: JSON { ["repo": .string(repo), "pr": JSON(number)] }

    /// The pull request and its findings; the board, the conversations and the errands beside them.
    func load(fresh: Bool = false) async throws {
        let store = Store.shared
        if store.supports("pulls") {
            Task {
                do { try await feed.loadBoard(fresh: fresh); rowRead = true; issueProjects.load() } catch {}
            }
        }
        if store.supports("sessions") { Task { try? await feed.loadSessions(fresh: fresh) } }
        Task { await ErrandCatalog.shared.load() }
        if section == .reviews { commentsLoad() }
        pullGen += 1
        let gen = pullGen
        readingPull = true
        defer { if gen == pullGen { readingPull = false } }
        let v: JSON
        do { v = try await store.call("pull", args) }
        catch {
            if gen == pullGen, let said = failure(error) { self.error = said }
            throw error
        }
        guard gen == pullGen else { return }
        pr = v["pr"]
        error = nil
        issueProjects.load()
        // The description is its own read, once per visit and on refresh.
        if pr["body"].string == nil && !bodyRead && !readingBody && store.supports("pull_description") { Task { await loadBody() } }
        if store.supports("findings") {
            do {
                let f = try await store.call("findings", args)
                guard gen == pullGen else { return }
                findings = f["findings"]; findingsError = nil
            } catch {
                if gen == pullGen, let said = failure(error) { findingsError = said }
            }
        }
        save()
    }
    private func loadBody() async {
        readingBody = true
        defer { readingBody = false }
        do {
            let v = try await Store.shared.call("pull_description", args)
            bodyRead = true
            descriptionBody = v["pr"]["body"].string ?? ""
            if let a = v["pr"]["author"].string { descriptionAuthor = a }
            save()
        } catch {
            if !error.isCancellation { bodyRead = true }
        }
    }

    /// Pulling down reads everything again, GitHub included; on the Run tab it reloads the page, as in a browser.
    func refresh() async {
        if section == .run, let browser { browser.reload(); return }
        editError = nil; branchNote = nil
        bodyRead = false
        issueProjects.reset()
        if section == .reviews { commentsCancel() }
        _ = await reading { try await load(fresh: true) }
    }

    func appeared() {
        shown = true
        profilesLoad()
        if section == .reviews { commentsLoad() }
        ensureBrowser()
    }
    func disappeared() {
        shown = false
        commentsCancel()
    }

    func select(_ s: PullSection) {
        if s == .run { runOpen(); return }
        section = s
        if s == .reviews { commentsLoad() }
    }

    // MARK: Comments and reviews

    /// Whether every list the server offers has been read once.
    var commentsRead: Bool { convAllRead(comments, supports: Store.shared.supports) }
    var commentItems: JSON { comments[ConvFeed.comments.rawValue].items }
    var reviewItems: JSON { comments[ConvFeed.reviews.rawValue].items }
    var lineItems: JSON { comments[ConvFeed.reviewComments.rawValue].items }
    /// The messages once they are read; until then the board's count of conversation comments.
    var commentCount: Int? {
        if commentsRead { return convCount(comments: commentItems, reviews: reviewItems, lines: lineItems) }
        return boardRow?.raw["comments"].int
    }

    /// Reads the comments, reviews and line comments afresh; what was read stays shown until the new lists are in.
    func commentsLoad() {
        for f in ConvFeed.allCases where !comments[f.rawValue].loading && Store.shared.supports(f.operation) {
            comments[f.rawValue].begin()
            commentTasks[f.rawValue] = Task { await commentPages(f) }
        }
    }
    private func commentPages(_ f: ConvFeed) async {
        var page = 1
        while true {
            do {
                let v = try await Store.shared.call(f.operation, ["repo": .string(repo), "pr": JSON(number), "page": JSON(page)])
                guard let next = comments[f.rawValue].take(v, feed: f, page: page) else { return }
                page = next
            } catch {
                comments[f.rawValue].fail(failure(error))
                return
            }
        }
    }
    private func commentsCancel() {
        for i in commentTasks.indices { commentTasks[i]?.cancel(); commentTasks[i] = nil }
        for i in comments.indices where comments[i].loading { comments[i].fail(nil) }
    }

    // MARK: Findings

    func decide(_ key: String, _ decision: String?) async {
        guard deciding == nil else { return }
        deciding = key
        defer { deciding = nil }
        var a = args
        a["key"] = .string(key); a["decision"] = .string(orNull: decision)
        do {
            let v = try await Store.shared.call("finding_decision", a)
            findings = v["findings"]; findingsError = nil
            save()
        } catch {
            if let said = failure(error) { findingsError = said }
        }
    }

    /// Solve findings is the board's implement-feedback errand started from the findings themselves: offered on an open
    /// pull request with findings still to fix, to a token that may start errands on a server that lists this one.
    func solveFindings(_ catalog: JSON) -> PendingErrand? {
        guard Store.shared.canManage, Store.shared.supports("action"), catalogLists(catalog, "implement-feedback") else { return nil }
        guard pr["state"].string == "open", let branch = pr["headRef"].string, findingsUnfixed(findings) > 0 else { return nil }
        // The errand as the server words it when it is on offer, else as this app knows it.
        guard let action = actions(catalog).first(where: { $0.id == "implement-feedback" })
                ?? BoardAction.known.first(where: { $0.id == "implement-feedback" }) else { return nil }
        return PendingErrand(action: action, number: number, branch: branch)
    }

    // MARK: Merge

    var canMerge: Bool { Store.shared.supports("merge_pull") && record.mergeable }
    /// Reads what GitHub says of the merge before asking, so the question can say what stands in the way of it.
    func askMerge() async {
        guard canMerge, !merging else { return }
        merging = true; mergeError = nil
        defer { merging = false }
        var files: JSON = .null
        var moved = false
        if Store.shared.supports("pull_files"), let page = try? await Store.shared.call("pull_files", args) {
            files = page
            if record.headMoved(files: page) {
                do { try await load() } catch { mergeError = failure(error); return }
                moved = true
            }
        }
        var notes = record.mergeNotes(files: files)
        if moved { notes.insert("New commits were pushed since this screen was read; it has been read again.", at: 0) }
        mergeQuestion = MergeQuestion(base: pr["baseRef"].string ?? "its base", notes: notes)
    }
    /// Squash-merges the head this screen was shown with (`headSha` guards against a push meanwhile).
    func merge() async {
        guard !merging, let a = record.mergeArguments(repo: repo) else { return }
        merging = true; mergeError = nil
        do {
            try await Store.shared.call("merge_pull", a)
        } catch {
            if let said = failure(error) {
                mergeError = (error as? APIError)?.isRefusal == true ? said
                    : "\(said) The merge may still have completed; check the state above before trying again."
            }
        }
        merging = false
        // The board still lists what was just merged until GitHub is asked again.
        _ = await reading { try await load(fresh: true) }
    }

    // MARK: Edits

    /// Edits on an open pull request, when the server takes `update_pull`.
    var canEdit: Bool { Store.shared.supports("update_pull") && record.isOpen }
    /// The description as last read, nil until it is: an edit starts from it.
    var pullBody: String? { record.body(described: descriptionBody) }
    var canUpdateBranch: Bool { Store.shared.supports("update_pull_branch") && record.branchUpdatable }

    /// Sends `fields` as an edit of this pull request. The title and description show as saved at once; the labels and
    /// assignees come back with the board's row, read again with the pull request.
    func edit(_ fields: JSON) async {
        guard !editing else { return }
        editing = true; editError = nil
        var a = fields
        a["repo"] = .string(repo); a["pr"] = JSON(number)
        do {
            let v = try await Store.shared.call("update_pull", a)
            let echo = PullRecord.editEcho(v, sent: a)
            var shown = record
            shown.apply(title: echo.title, body: echo.body)
            pr = shown.pr
            if let body = echo.body { descriptionBody = body }
            save()
        } catch {
            // An edit sets what it names, so trying again is safe.
            if let said = failure(error) { editError = said }
        }
        editing = false
        _ = await reading { try await load(fresh: true) }
    }

    /// Merges the base into the branch on GitHub, at the head and base last read, once confirmed.
    func updateBranch() async {
        guard !updatingBranch, !merging, let a = record.updateBranchArguments(repo: repo), let base = a["baseRef"].string else { return }
        updatingBranch = true; mergeError = nil; branchNote = nil
        do {
            try await Store.shared.call("update_pull_branch", a)
            branchNote = "GitHub is merging \(base) into this branch; its new commit and checks show once it has."
        } catch {
            if let said = failure(error) {
                mergeError = (error as? APIError)?.isRefusal == true ? said : "\(said) The update may still have been made; pull down to refresh before trying again."
            }
        }
        updatingBranch = false
        _ = await reading { try await load() }
    }

    // MARK: Conversations

    func delete(_ id: String) async {
        guard deletingRun == nil, Store.shared.supports("delete") else { return }
        deletingRun = id; runError = nil
        defer { deletingRun = nil }
        do {
            try await Store.shared.call("delete", ["sessionId": .string(id)])
            if id == runSession || id == logSession { runForget() }
            feed.drop(id)
        } catch {
            if let said = failure(error) { runError = said }
        }
        // A list read while the delete was in flight may still hold the row.
        if Store.shared.supports("sessions") { try? await feed.loadSessions(fresh: true) }
    }

    // MARK: Run

    /// The profile the tab shows as chosen: the one picked, else the one served, else the project's default.
    var shownProfile: String? { serve.shownProfile(profiles) }
    /// The session the Run tab shows: the one serving it, else the one being prepared for it.
    var runTarget: String? { runSession ?? logSession }
    var pageURL: String? { browser?.url ?? runURL }
    var runOffered: Bool { Store.shared.supports("serve_pull") || runURL != nil }

    /// The Run tab's session was deleted, and the workspace serving it with it: the tab gives way to the description.
    private func runForget() {
        runPending = false
        serve.forget()
        logSession = nil; log.clear()
        setBrowser(nil)
        if section == .run { section = .description }
    }
    private func setBrowser(_ b: RunBrowser?) {
        browser = b
        browserSink = b?.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
    }
    private func profilesLoad() {
        guard !profilesRead, !readingProfiles, Store.shared.supports("projects"), Store.shared.supports("serve_pull") else { return }
        readingProfiles = true
        Task {
            defer { readingProfiles = false }
            guard let v = try? await Store.shared.call("projects") else { return }
            profilesRead = true
            profiles = runProfilesParse(v, repo: repo)
        }
    }
    /// The Run tab was opened: reads the project's run profiles once, and serves the pull request unless it is served.
    func runOpen() {
        section = .run
        profilesLoad()
        // Until the conversations are read, a Run serving this pull request may be among them.
        if Store.shared.supports("sessions") && !feed.sessionsLoaded {
            guard !runPending else { return }
            runPending = true
            Task {
                try? await feed.loadSessions()
                guard runPending else { return }
                runPending = false
                runResume()
            }
        } else { runResume() }
        ensureBrowser()
    }
    private func runResume() {
        if serve.needsServing && !runAdopt() { runStart() }
    }
    /// A Run already serving this pull request (one of its sessions with serve links) is shown as it is.
    private func runAdopt() -> Bool {
        guard let (id, url) = runSessionServing(Session.json(runs), number: number) else { return false }
        if serve.url != url { setBrowser(nil) }
        serve.adopt(session: id, url: url)
        ensureBrowser()
        return true
    }
    /// Serves the pull request: the run's session again, with the picked profile, when there is one; else a new session,
    /// which the server serves with the project's default profile.
    func runStart() {
        guard let request = serve.start(repo: repo, number: number, canSwitch: Store.shared.supports("serve")) else { return }
        if let profile = request.switchingTo { log.add("▶ Switching to profile \(profile)", error: false) }
        Task {
            do { runDone(.success(try await Store.shared.call(request.operation, request.arguments, timeout: RunRequest.timeout)), switched: request.switched) }
            catch { runDone(.failure(error), switched: request.switched) }
        }
    }
    private func runDone(_ r: Result<JSON, Error>, switched: Bool) {
        switch r {
        case .failure(let error):
            guard let said = failure(error) else { serve.cancelled(); return }
            let e = error as? APIError
            if serve.failed(said, status: e?.status, message: e?.message, switched: switched) { setBrowser(nil) }
        case .success(let v):
            let served = serve.served(v)
            if served.show != nil && !served.reload { setBrowser(nil) }
            if served.reload { browser?.reload() }
            if served.startAgain { runStart(); return }
            if Store.shared.supports("sessions") { Task { try? await feed.loadSessions(fresh: true) } }
        }
        ensureBrowser()
    }
    func pickProfile(_ profile: String) {
        if serve.pick(profile, profiles: profiles) { runStart() }
    }

    /// The browser starts once the tab is on show with an address, and once the service token that lets it past
    /// Cloudflare Access has been read.
    func ensureBrowser() {
        guard shown, section == .run, let url = runURL, !runBusy, browser == nil else { return }
        if !accessRead && Store.shared.supports("preview_access") {
            guard !readingAccess else { return }
            readingAccess = true
            Task {
                defer { readingAccess = false }
                do {
                    let v = try await Store.shared.call("preview_access")
                    if let id = v["clientId"].string, let secret = v["clientSecret"].string, let suffix = v["hostSuffix"].nonEmpty {
                        access = RunWebAccess(clientID: id, clientSecret: secret, hostSuffix: suffix)
                    }
                } catch {
                    if error.isCancellation { return }
                }
                accessRead = true
                ensureBrowser()
            }
            return
        }
        let b = RunBrowser(profile: "preview", access: access)
        setBrowser(b)
        b.load(url)
    }

    private func logFollow(_ session: String) {
        if logSession == session { return }
        logSession = session
        log.clear()
    }
    /// While `serve_pull` prepares the session its id is not known yet: the newest ▶ Run session on this pull request is it.
    func runLogTick() async {
        guard runBusy, !readingLog else { return }
        if let s = runSession { logFollow(s) }
        readingLog = true
        defer { readingLog = false }
        if let session = logSession, Store.shared.supports("session") {
            guard let v = try? await Store.shared.call("session", ["sessionId": .string(session), "since": JSON(log.cursor)]), session == logSession else { return }
            log.addEvents(v["events"])
        } else if runSession == nil && Store.shared.supports("sessions") {
            guard let v = try? await Store.shared.call("sessions", ["repo": .string(repo)]), runSession == nil else { return }
            if let id = runSessionPreparing(v, number: number) { logFollow(id) }
        }
    }
}
