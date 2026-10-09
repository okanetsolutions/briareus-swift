// A project's Run tab on its board, after Issues (the Windows client's project_run.c): the pull request's Run tab, on the
// project's default branch. Opening it serves the branch in a clean workspace with the project's run commands
// (`serve_branch`, no agent turn) and shows it in an embedded browser under an address bar, with the setup's console until
// the page is up. The header picks the run profile and deletes the run with its workspace.
import Combine
import SwiftUI

@MainActor
final class ProjectRunModel: ObservableObject {
    let repo: String
    // `session` serves the branch at `url` with `profile`; `want` is the profile picked in the header, `asked` the one the
    // request in flight asked for. `branch` is what the server served, once it said.
    @Published private(set) var url: String?
    @Published private(set) var session: String?
    @Published private(set) var profile: String?
    @Published private(set) var want: String?
    @Published private(set) var asked: String?
    @Published private(set) var branch: String?
    @Published private(set) var serveError: String?
    @Published private(set) var deleteError: String?
    @Published private(set) var busy = false
    @Published private(set) var deleting = false
    /// Waits for the project's sessions, in case a Run already serves the branch.
    @Published private(set) var pending = false
    private var sessionsRead = false, readingSessions = false
    /// The project's run profiles, the default first.
    @Published private(set) var profiles: [String] = []
    private var profilesRead = false, readingProfiles = false
    /// The log of the Run under way, from its session's transcript: `logSession` is the session followed (found among the
    /// project's sessions while `serve_branch` prepares it).
    @Published private(set) var logSession: String?
    @Published private(set) var log = RunLog()
    private var readingLog = false
    /// Which serve is the tab's: a delete forgets the one in flight, whose answer is then dropped.
    private var serveGen = 0
    @Published private(set) var browser: Browser?
    private var browserSink: AnyCancellable?
    /// The Cloudflare Access service token the browser sends to preview hosts, read once before it first opens.
    private var access: WebAccess?
    private var accessRead = false, readingAccess = false
    /// Whether the tab is on show, which the browser waits for.
    var shown = false

    init(repo: String) {
        self.repo = repo
        // The profiles the sidebar already read stand in until the tab reads them.
        profiles = runProfilesParse(ProjectsModel.shared.raw, repo: repo)
    }

    /// Whether this token may serve a branch, on a server that can.
    static var offered: Bool { Store.shared.canManage && Store.shared.supports("serve_branch") }

    /// The session the tab shows: the one serving it, else the one being prepared for it.
    var target: String? { session ?? logSession }
    /// The profile shown as chosen: the one picked, else the one served, else the project's default.
    var shownProfile: String? { want ?? profile ?? profiles.first }
    var pageURL: String? { browser?.url ?? url }

    private func setBrowser(_ b: Browser?) {
        browser = b
        browserSink = b?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    /// Shows the served address, starting the browser again when the address changed.
    private func show(_ address: String) {
        if url != address { setBrowser(nil); url = address }
    }
    private func branchFrom(_ session: JSON) {
        if let b = session["startBranch"].nonEmpty ?? session["branch"].nonEmpty { branch = b }
    }

    // MARK: - Opening

    /// The tab was opened: reads the run profiles once, and serves the branch unless a Run already serves it.
    func open() {
        if !profilesRead && !readingProfiles && Store.shared.supports("projects") {
            readingProfiles = true
            Task {
                let r = await boardCall("projects")
                readingProfiles = false
                guard let v = r.value else { return }
                profilesRead = true
                profiles = runProfilesParse(v, repo: repo)
            }
        }
        // Until the project's sessions are read, a Run serving the branch may be among them.
        if !sessionsRead && Store.shared.supports("sessions") {
            pending = true
            if !readingSessions { Task { await readSessions() } }
        } else { resume() }
    }
    private func resume() { if url == nil && !busy && serveError == nil { start() } }
    /// A Run already serving the branch (a branch preview with a serve link) is shown as it is.
    private func readSessions() async {
        readingSessions = true
        let r = await boardCall("sessions", ["repo": .string(repo)])
        readingSessions = false
        if r.error?.kind == .cancelled { pending = false; return }
        sessionsRead = true
        if let v = r.value, url == nil, !busy, let (id, address) = runSessionServingBranch(v) {
            session = id
            if let row = listOf(v, "sessions").items.first(where: { $0["id"].string == id }) { branchFrom(row) }
            show(address)
        }
        if pending { pending = false; resume() }
    }

    // MARK: - Serving

    /// Serves the branch: the run's session again, with the picked profile, when there is one; else a new session, which
    /// the server serves with the project's default profile (switched afterwards when another was picked).
    func start() {
        guard !busy else { return }
        busy = true; serveError = nil
        var args: JSON = [:]
        var op = "serve_branch"
        let switched: Bool
        if let session, Store.shared.supports("serve") {
            op = "serve"
            args["sessionId"] = .string(session)
            if let want { args["profile"] = .string(want) }
            asked = want
            switched = true
        } else {
            args["repo"] = .string(repo)
            switched = false
        }
        if let asked { log.add("▶ Switching to profile \(asked)", error: false) }
        serveGen += 1
        let gen = serveGen
        Task {
            let r = await boardCall(op, args, timeout: 170)
            if gen == serveGen { done(r, switched: switched) }
        }
    }
    private func done(_ r: Result<JSON, APIError>, switched: Bool) {
        busy = false
        let asked = self.asked
        self.asked = nil
        switch r {
        case .failure(let e):
            if e.kind == .cancelled { return }
            serveError = e.description
            if switched && (e.status == 404 || (e.message ?? "").contains("no live workspace")) {
                // The session closed or expired, and its page with it: the next try prepares a new one.
                session = nil; url = nil
                setBrowser(nil)
            } else if switched {
                // A refused switch leaves the app serving what it served.
                want = profile
            }
        case .success(let v):
            if let id = v["session"]["id"].string { session = id }
            branchFrom(v["session"])
            profile = v["profile"].string
            if let address = v["url"].string, safeWebURL(address) {
                let same = address == url
                show(address)
                // The same address after a restart is a new app behind it.
                if same { browser?.reload() }
            } else { serveError = "The server did not say where it serves the branch." }
            // A profile picked while this request was out, or a new session served with the default.
            if let want, session != nil, want != asked, want != profile { start() }
        }
    }
    func pickProfile() {
        guard !profiles.isEmpty else { return }
        let shown = shownProfile
        let items = profiles.enumerated().map { i, p in BoardPopupMenu.Item(title: i == 0 ? "\(p) (default)" : p, checked: p == shown) }
        guard let chosen = BoardPopupMenu.show(items, rightAligned: true), profiles[chosen] != shown else { return }
        want = profiles[chosen]
        // While a request is out, its answer switches to the new pick.
        if !busy { start() }
    }
    /// F5 reloads the page, as in a browser; with none up, it tries again.
    func refresh() {
        if let browser { browser.reload(); return }
        if !busy { serveError = nil; start() }
    }

    // MARK: - Deleting

    /// The run's session was deleted, and the workspace serving it with it: opening the tab again prepares a new one.
    private func forget() {
        serveGen += 1
        busy = false
        session = nil; url = nil; profile = nil; asked = nil; serveError = nil
        logSession = nil; log.clear()
        setBrowser(nil)
    }
    func deleteRun() {
        guard let id = target, !deleting, Store.shared.supports("delete") else { return }
        let ok = Dialogs.confirm("Delete this run?", "Its workspace stops serving the branch, and its conversation and transcript are deleted permanently.",
                                 continueLabel: "Delete", destructive: true)
        // The run may have changed while the dialog was open: delete the one asked about only if it is still shown.
        guard ok, !deleting, id == target else { return }
        deleting = true; deleteError = nil
        Task {
            let r = await boardCall("delete", ["sessionId": .string(id)])
            deleting = false
            if let e = r.error { deleteError = e.description; return }
            if id == session || id == logSession { forget() }
            // The sidebar drops the row now instead of at its next poll.
            post(.sessionForgotten, ["id": id, "repo": repo])
        }
    }

    // MARK: - The browser and the log

    /// The browser starts once the tab is first on show with an address, and once the service token that lets it past
    /// Cloudflare Access has been read.
    func ensureBrowser() {
        guard shown, let url, !busy, browser == nil else { return }
        if !accessRead && Store.shared.supports("preview_access") {
            guard !readingAccess else { return }
            readingAccess = true
            Task {
                let r = await boardCall("preview_access")
                readingAccess = false
                if r.error?.kind == .cancelled { return }
                accessRead = true
                if let v = r.value, let id = v["clientId"].string, let secret = v["clientSecret"].string, let suffix = v["hostSuffix"].nonEmpty {
                    access = WebAccess(clientID: id, clientSecret: secret, hostSuffix: suffix)
                }
                ensureBrowser()
            }
            return
        }
        let b = Browser(profile: "preview", access: access)
        setBrowser(b)
        b.load(url)
    }

    private func follow(_ s: String) {
        if logSession == s { return }
        logSession = s
        log.clear()
    }
    /// While `serve_branch` prepares the session, its id is not known yet: the newest branch preview of the project is it.
    func logTick() async {
        guard busy, !readingLog else { return }
        if let s = session { follow(s) }
        readingLog = true
        defer { readingLog = false }
        if let s = logSession, Store.shared.supports("session") {
            guard let v = await boardCall("session", ["sessionId": .string(s), "since": JSON(log.cursor)]).value, s == logSession else { return }
            log.addEvents(v["events"])
        } else if session == nil && Store.shared.supports("sessions") {
            guard let v = await boardCall("sessions", ["repo": .string(repo)]).value, session == nil else { return }
            if let id = runSessionPreparingBranch(v) { follow(id) }
        }
    }

    // MARK: - The header

    /// The branch under the title, and the profile picker and Delete; the address bar over the page has the rest.
    var subtitle: String { "\(repo) \u{00B7} \(branch ?? "default branch")" }
    var headerButtons: [HeaderButton] {
        var buttons: [HeaderButton] = []
        if !profiles.isEmpty {
            buttons.append(HeaderButton(glyph: "slider.horizontal.3", label: "\(shownProfile ?? "") ▾", tip: "The run profile it is served with") { [weak self] in self?.pickProfile() })
        }
        if Store.shared.supports("delete") {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74D), tip: "Delete this run and its workspace", enabled: target != nil && !deleting,
                                        destructive: true) { [weak self] in self?.deleteRun() })
        }
        return buttons
    }
}

/// The tab: the browser's area under its address bar, down to the bottom of the pane, with what is happening written in
/// it until the page is up.
struct ProjectRunTab: View {
    @ObservedObject var model: ProjectRunModel
    @StateObject private var feedback = PreviewFeedback()

    var body: some View {
        let browser = model.browser
        let page = model.url != nil && !model.busy && browser != nil && browser?.error == nil
        VStack(alignment: .leading, spacing: 0) {
            if let e = model.deleteError { Notice(message: e).padding(.bottom, 10) }
            if page, let e = model.serveError {
                Text(e).font(Theme.footnote).foregroundStyle(Theme.danger).lineLimit(1).truncationMode(.tail).padding(.bottom, 10)
            }
            if model.url != nil && !model.busy { RunBrowserBar(browser: browser, url: model.url, session: model.session, feedback: feedback) }
            ZStack(alignment: .topLeading) {
                if let browser, page {
                    BrowserView(browser: browser).opacity(browser.ready ? 1 : 0)
                    if let s = model.session { PreviewFeedbackLayer(feedback: feedback, browser: browser, session: s) }
                }
                if !(page && browser?.ready == true) { status }
            }
            .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.bottom, 12)
        .onAppear { model.shown = true; model.ensureBrowser() }
        .onDisappear { model.shown = false }
        .task(id: "\(model.url ?? "")|\(model.busy)|\(browser == nil)") { model.ensureBrowser() }
        // The setup's log while the branch is being served, every second and a half.
        .task(id: model.busy) {
            while model.busy && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                await model.logTick()
            }
        }
    }

    private func statusText(_ error: String?) -> String? {
        if let error { return error }
        if model.busy && model.url != nil { return model.asked.map { "Restarting with profile \($0)…" } ?? "Serving it again…" }
        if model.url != nil { return "Starting the browser…" }
        if model.busy && model.session != nil { return "Serving it…" }
        // Once the setup's console has lines it says what is happening; until then, a line saying what is coming.
        if !model.log.lines.isEmpty { return nil }
        if model.busy || model.pending { return "Preparing a workspace on the default branch and serving it with the project’s run commands. This can take a few minutes…" }
        return nil
    }

    @ViewBuilder private var status: some View {
        let error: String? = model.busy ? nil : model.url == nil ? model.serveError : model.browser?.error
        let text = statusText(error)
        VStack(alignment: .leading, spacing: 0) {
            if let text {
                Text(text).font(Theme.body).foregroundStyle(error != nil ? Theme.danger : Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if model.url == nil && model.serveError != nil && !model.busy {
                Button("▶ Try again") { model.start() }.dashButton(.bordered).padding(.top, 10)
            } else if error != nil && model.url != nil {
                Button("Open in your browser instead ↗") { openWebURL(model.pageURL) }.buttonStyle(.plain).font(Theme.body).foregroundStyle(Theme.accent).padding(.top, 8)
            }
            // The setup as it happens, its latest lines filling what is left of the area, as a terminal does.
            if !model.log.lines.isEmpty && (model.busy || model.url == nil) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.log.lines.enumerated()), id: \.offset) { _, l in
                            Text(l.text).font(Theme.monoSmall).foregroundStyle(l.isError ? Theme.danger : Theme.muted)
                                .lineLimit(1).truncationMode(.tail).frame(height: 17, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sunken))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
                .padding(.top, 12)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
