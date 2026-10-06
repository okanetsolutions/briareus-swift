// ▶ Run on a project's default branch, on a phone (the Mac's ProjectRunTab): the pull request's Run section, for the branch
// the project starts from. Opening it serves the branch in a clean workspace with the project's run commands
// (`serve_branch`, no agent turn) and shows it in the embedded browser, with the setup's log until the page is up; a Run
// already serving the branch is shown as it is. The toolbar's menu picks the run profile, reloads the page, opens it in
// Safari, and deletes the run with its workspace.
import Combine
import SwiftUI

@MainActor
final class BranchRunModel: ObservableObject {
    let repo: String
    // `session` serves the branch at `url` with `profile`; `want` is the profile picked, `asked` the one the request in
    // flight asked for. `branch` is what the server served, once it said.
    @Published private(set) var url: String?
    @Published private(set) var session: String?
    @Published private(set) var profile: String?
    @Published private(set) var want: String?
    @Published private(set) var asked: String?
    @Published private(set) var branch: String?
    @Published private(set) var serveError: String?
    @Published var deleteError: String?
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
    /// Which serve is the screen's: a delete forgets the one in flight, whose answer is then dropped.
    private var serveGen = 0
    @Published private(set) var browser: RunBrowser?
    private var browserSink: AnyCancellable?
    /// The Cloudflare Access service token the browser sends to preview hosts, read once before it first opens.
    private var access: RunWebAccess?
    private var accessRead = false, readingAccess = false
    /// Whether the screen is on show, which the browser waits for.
    var shown = false

    init(repo: String) {
        self.repo = repo
        // The profiles the projects list already read stand in until the screen reads them.
        profiles = runProfilesParse(ProjectsModel.shared.raw, repo: repo)
    }

    /// Whether this token may serve a branch, on a server that can.
    static var offered: Bool { Store.shared.canManage && Store.shared.supports("serve_branch") }

    /// The session the screen shows: the one serving it, else the one being prepared for it.
    var target: String? { session ?? logSession }
    /// The profile shown as chosen: the one picked, else the one served, else the project's default.
    var shownProfile: String? { want ?? profile ?? profiles.first }
    var pageURL: String? { browser?.url ?? url }

    private func setBrowser(_ b: RunBrowser?) {
        browser = b
        browserSink = b?.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
    }
    /// Shows the served address, starting the browser again when the address changed.
    private func show(_ address: String) {
        if url != address { setBrowser(nil); url = address }
        ensureBrowser()
    }
    private func branchFrom(_ session: JSON) {
        if let b = session["startBranch"].nonEmpty ?? session["branch"].nonEmpty { branch = b }
    }

    // MARK: Opening

    /// The screen was opened: reads the run profiles once, and serves the branch unless a Run already serves it.
    func open() {
        if !profilesRead && !readingProfiles && Store.shared.supports("projects") {
            readingProfiles = true
            Task {
                defer { readingProfiles = false }
                guard let v = try? await Store.shared.call("projects") else { return }
                profilesRead = true
                profiles = runProfilesParse(v, repo: repo)
            }
        }
        // Until the project's sessions are read, a Run serving the branch may be among them.
        if !sessionsRead && Store.shared.supports("sessions") {
            pending = true
            if !readingSessions { Task { await readSessions() } }
        } else { resume() }
        ensureBrowser()
    }
    private func resume() { if url == nil && !busy && serveError == nil { start() } }
    /// A Run already serving the branch (a branch preview with a serve link) is shown as it is.
    private func readSessions() async {
        readingSessions = true
        defer { readingSessions = false }
        let v: JSON
        do { v = try await Store.shared.call("sessions", ["repo": .string(repo)]) }
        catch {
            if error.isCancellation { pending = false; return }
            v = .null
        }
        sessionsRead = true
        if url == nil, !busy, let (id, address) = runSessionServingBranch(v) {
            session = id
            if let row = listOf(v, "sessions").items.first(where: { $0["id"].string == id }) { branchFrom(row) }
            show(address)
        }
        if pending { pending = false; resume() }
    }

    // MARK: Serving

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
            let r: Result<JSON, Error>
            do { r = .success(try await Store.shared.call(op, args, timeout: 170)) } catch { r = .failure(error) }
            if gen == serveGen { done(r, switched: switched) }
        }
    }
    private func done(_ r: Result<JSON, Error>, switched: Bool) {
        busy = false
        let asked = self.asked
        self.asked = nil
        switch r {
        case .failure(let error):
            guard let said = failure(error) else { return }
            serveError = said
            let e = error as? APIError
            if switched && (e?.status == 404 || (e?.message ?? "").contains("no live workspace")) {
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
            if let want, session != nil, want != asked, want != profile { start(); return }
            if Store.shared.supports("sessions") { Task { try? await Store.shared.feed(repo).loadSessions(fresh: true) } }
        }
        ensureBrowser()
    }
    func pickProfile(_ picked: String) {
        guard picked != shownProfile else { return }
        want = picked
        // While a request is out, its answer switches to the new pick.
        if !busy { start() }
    }
    /// Pulling down reloads the page, as in a browser; with none up, it tries again.
    func refresh() {
        if let browser { browser.reload(); return }
        if !busy { serveError = nil; start() }
    }

    // MARK: Deleting

    /// The run's session was deleted, and the workspace serving it with it: opening the screen again prepares a new one.
    private func forget() {
        serveGen += 1
        busy = false
        session = nil; url = nil; profile = nil; asked = nil; serveError = nil
        logSession = nil; log.clear()
        setBrowser(nil)
    }
    func deleteRun() async {
        guard let id = target, !deleting, Store.shared.supports("delete") else { return }
        deleting = true; deleteError = nil
        defer { deleting = false }
        do {
            try await Store.shared.call("delete", ["sessionId": .string(id)])
            if id == session || id == logSession { forget() }
            Store.shared.feed(repo).drop(id)
        } catch {
            if let said = failure(error) { deleteError = said }
        }
    }

    // MARK: The browser and the log

    /// The browser starts once the screen is on show with an address, and once the service token that lets it past
    /// Cloudflare Access has been read.
    func ensureBrowser() {
        guard shown, let url, !busy, browser == nil else { return }
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
            guard let v = try? await Store.shared.call("session", ["sessionId": .string(s), "since": JSON(log.cursor)]), s == logSession else { return }
            log.addEvents(v["events"])
        } else if session == nil && Store.shared.supports("sessions") {
            guard let v = try? await Store.shared.call("sessions", ["repo": .string(repo)]), session == nil else { return }
            if let id = runSessionPreparingBranch(v) { follow(id) }
        }
    }
}

/// The screen: the page once it is up, edge to edge, and until then what is happening, with the setup's log as it runs.
struct BranchRunScreen: View {
    let repo: String
    @EnvironmentObject private var store: Store
    @StateObject private var model: BranchRunModel
    @State private var confirmingDelete = false

    init(repo: String) {
        self.repo = repo
        _model = StateObject(wrappedValue: BranchRunModel(repo: repo))
    }

    var body: some View {
        let browser = model.browser
        let page = model.url != nil && !model.busy && browser != nil && browser?.error == nil
        VStack(alignment: .leading, spacing: 0) {
            if let e = model.deleteError { ErrorNotice(message: e).padding(.horizontal, 16).padding(.vertical, 8) }
            if page, let e = model.serveError {
                Text(e).font(.footnote).foregroundStyle(Theme.danger).lineLimit(2).padding(.horizontal, 16).padding(.vertical, 8)
            }
            ZStack(alignment: .topLeading) {
                if let browser, page { RunBrowserView(browser: browser).opacity(browser.ready ? 1 : 0) }
                if !(page && browser?.ready == true) { status }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.background)
        .navigationTitle(model.branch ?? "Default branch").navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear { model.shown = true; model.open() }
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
        .alert("Delete this run?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await model.deleteRun() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its workspace stops serving the branch, and its conversation and transcript are deleted permanently.")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Button { model.refresh() } label: { Label(model.browser != nil ? "Reload page" : "Try again", systemImage: "arrow.clockwise") }
                        .disabled(model.busy || (model.browser != nil && !(model.browser?.ready ?? false)))
                    if safeWebURL(model.pageURL) {
                        Button { boardOpenWeb(model.pageURL) } label: { Label("Open page in Safari", systemImage: "safari") }
                    }
                }
                if !model.profiles.isEmpty {
                    Picker(selection: Binding(get: { model.shownProfile ?? "" }, set: { model.pickProfile($0) })) {
                        ForEach(Array(model.profiles.enumerated()), id: \.offset) { i, p in Text(i == 0 ? "\(p) (default)" : p).tag(p) }
                    } label: {
                        Label("Run profile: \(model.shownProfile ?? "")", systemImage: "slider.horizontal.3")
                    }
                    .pickerStyle(.menu)
                }
                if model.target != nil, store.supports("delete") {
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete this run", systemImage: "trash") }
                        .disabled(model.deleting)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    private func statusText(_ error: String?) -> String? {
        if let error { return error }
        if model.busy && model.url != nil { return model.asked.map { "Restarting with profile \($0)…" } ?? "Serving it again…" }
        if model.url != nil { return "Starting the browser…" }
        if model.busy && model.session != nil { return "Serving it…" }
        // Once the setup's log has lines it says what is happening; until then, a line saying what is coming.
        if !model.log.lines.isEmpty { return nil }
        if model.busy || model.pending { return "Preparing a workspace on the default branch and serving it with the project’s run commands. This can take a few minutes…" }
        return nil
    }

    @ViewBuilder private var status: some View {
        let error: String? = model.busy ? nil : model.url == nil ? model.serveError : model.browser?.error
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if model.busy || model.pending || (model.url != nil && error == nil) { ProgressView() }
                if let text = statusText(error) {
                    Text(text).font(.callout).foregroundStyle(error != nil ? Theme.danger : .secondary)
                }
            }
            if model.url == nil && model.serveError != nil && !model.busy {
                Button { model.start() } label: { Label("Try again", systemImage: "play.fill") }.buttonStyle(.bordered)
            } else if error != nil && model.url != nil {
                Button { boardOpenWeb(model.pageURL) } label: { Label("Open in Safari instead", systemImage: "safari") }
            }
            // The setup as it happens, its latest lines at the bottom, as a terminal shows them.
            if !model.log.lines.isEmpty && (model.busy || model.url == nil) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.log.lines.enumerated()), id: \.offset) { _, l in
                            Text(l.text).font(.caption2.monospaced()).foregroundStyle(l.isError ? Theme.danger : .secondary)
                                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .textSelection(.enabled)
                }
                .defaultScrollAnchor(.bottom)
                .background(Theme.code, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
