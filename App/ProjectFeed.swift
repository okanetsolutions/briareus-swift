// What the screens of a project share: its conversations and its board, each asked for once however many screens show
// them; and the projects themselves, with the overview of what waits for you and what is working across them.
import Combine
import SwiftUI

@MainActor
final class ProjectFeed: ObservableObject {
    /// How often a screen showing the conversations or the board asks for them again. The board costs the server a
    /// question to GitHub each time, so it is left longer than the server keeps its own answer.
    static let sessionsEvery = 7.0, boardEvery = 60.0

    let repo: String
    @Published private(set) var sessions: [Session] = []
    /// True once the conversations were read, from what was saved or from the server.
    @Published private(set) var sessionsLoaded = false
    /// The board as the server sent it (`pulls` and `issues`), which is what is saved and what names the stacks.
    @Published private(set) var board: JSON = .null {
        // Parsed once per answer: the screens read these on every redraw, and a busy repository's board is hundreds of
        // kilobytes to walk.
        didSet { parseBoard() }
    }
    @Published private(set) var boardLoaded = false
    /// True while the pull request list is being read, including a refresh with cached rows still on screen.
    @Published private(set) var boardReading = false
    private var boardReadCount = 0
    /// The board's pull requests and issues, each issue with what the server sent for it.
    private(set) var pulls: [PullSummary] = []
    private(set) var issues: [(summary: IssueSummary, raw: JSON)] = []
    private func parseBoard() {
        pulls = PullSummary.parseList(board["pulls"])
        issues = board["issues"].items.compactMap { j in IssueSummary(j).map { ($0, j) } }
    }

    private struct Reading {
        var at: Date?
        var task: Task<Void, Error>?
    }
    private var readingSessions = Reading()
    private var readingBoard = Reading()

    init(repo: String) {
        self.repo = repo
        if let saved = Store.shared.cache.value("sessions:\(repo)").flatMap(Session.parseList) { sessions = saved; sessionsLoaded = true }
        if let saved = Store.shared.cache.value("pulls:\(repo)") { board = saved; boardLoaded = true; parseBoard() }
    }

    /// `fresh` asks the server whatever was read a moment ago, as after a write or a pull to refresh. While the live
    /// stream brings the changes (LiveFeed.swift), a poll asks only once a minute, in case one was missed.
    func loadSessions(fresh: Bool = false) async throws {
        let every = SessionFeed.shared.live ? 60 : Self.sessionsEvery
        try await read(\.readingSessions, every: every, fresh: fresh) { [self] in
            let answer = try await Store.shared.call("sessions", ["repo": .string(repo)])
            guard let list = Session.parseList(listOf(answer, "sessions")) else { throw APIError(.nonJSON) }
            adopt(list)
        }
    }
    /// What another screen read of the project's conversations, such as the projects list's read of every one.
    func adopt(_ list: [Session]) {
        let gone = Set(sessions.map(\.id)).subtracting(list.map(\.id))
        if list != sessions { sessions = list }
        sessionsLoaded = true
        Store.shared.cache.store(Session.json(list), "sessions:\(repo)")
        for id in gone { Store.shared.cache.remove("transcript:\(id)") }
        ProjectsModel.shared.recount()
    }
    /// A deleted conversation leaves the list at once, before the server is asked again.
    func drop(_ id: String) {
        remove(id)
    }
    /// A record from the live stream, in its row's place or first when new; the overview and its badge follow it, as a
    /// turn starting or ending, a question asked or a review round held all change them.
    func upsert(_ s: Session) {
        let saved = Store.shared.cache.upsertSession(s, repo: repo)
        guard let list = saved ?? sessions.upserting(s) else { return }
        sessions = list
        if saved != nil { sessionsLoaded = true }
        ProjectsModel.shared.recount()
    }
    /// A conversation the live stream says was deleted, if it is in this list.
    func remove(_ id: String) {
        let saved = Store.shared.cache.removeSession(id, repo: repo)
        guard let list = saved ?? sessions.removing(id) else { return }
        sessions = list
        if saved != nil { sessionsLoaded = true }
        Store.shared.cache.remove("transcript:\(id)")
        ProjectsModel.shared.recount()
    }

    /// When each repository's pull request list may be read again, shared by every project's feed.
    private static var cooldown = PullsCooldown()

    /// Other lists reading through this feed respect the same repository cooldown.
    static func boardDeadline(_ repo: String) -> Date? { cooldown.deadline(repo) }
    static func boardCooldownError(_ repo: String) -> APIError? { cooldown.error(repo) }

    /// `fresh` also has the server ask GitHub again instead of answering from its own short cache.
    func loadBoard(fresh: Bool = false) async throws {
        // While the server's cooldown on the list runs (a spent GitHub allowance), the board shown stays as it is.
        if !Self.cooldown.mayRead(repo) { return }
        if !fresh, let task = readingBoard.task { return try await task.value }
        let stale = pullsNeedRefresh(board, now: Store.shared.client?.serverNow)
        try await read(\.readingBoard, every: Self.boardEvery, fresh: fresh || stale) { [self] in
            boardReadCount += 1
            boardReading = true
            defer {
                boardReadCount -= 1
                boardReading = boardReadCount > 0
            }
            var answer: JSON
            do {
                answer = try await readPulls(fresh: fresh, now: { Store.shared.client?.serverNow }) { fresh in
                    try await Store.shared.call("pulls", fresh ? ["repo": .string(repo), "fresh": "1"] : ["repo": .string(repo)])
                }
                Self.cooldown.succeeded(repo)
            } catch let e as APIError {
                Self.cooldown.failed(repo, error: e)
                throw e
            }
            if answer != board { board = answer }
            boardLoaded = true
            Store.shared.cache.store(answer, "pulls:\(repo)")
        }
    }

    /// Opening the PR tab reuses a recent GitHub sync, including one already in flight. Returns whether a read answered.
    func refreshBoardIfStale() async throws -> Bool {
        var answered = false
        if let task = readingBoard.task { try await task.value; answered = true }
        guard pullsNeedRefresh(board, now: Store.shared.client?.serverNow), Self.cooldown.mayRead(repo) else { return answered }
        try await loadBoard()
        return true
    }

    /// One request at a time. A poll finding an answer young enough asks nothing, and one finding a request on its way
    /// waits for that answer. A fresh read lets such a request land first and then asks again, so what is shown last is
    /// what the server said last. The request belongs to the feed: a screen that leaves while it is out does not take it
    /// along, since another may be waiting on it.
    private func read(_ reading: ReferenceWritableKeyPath<ProjectFeed, Reading>, every interval: Double, fresh: Bool,
                      _ request: @escaping @MainActor () async throws -> Void) async throws {
        if let asked = self[keyPath: reading].task {
            if !fresh { return try await asked.value }
            _ = try? await asked.value
        } else if !fresh, let at = self[keyPath: reading].at, abs(Date().timeIntervalSince(at)) < interval - 1 { return }
        let asking = Task { try await request() }
        self[keyPath: reading].task = asking
        defer { if self[keyPath: reading].task == asking { self[keyPath: reading].task = nil } }
        try await asking.value
        self[keyPath: reading].at = Date()
    }
}

/// The projects this device can read, and what waits for you and what is working across them, for the Findings tab and
/// its badge, and every screen that picks a project.
@MainActor
final class ProjectsModel: ObservableObject {
    static let shared = ProjectsModel()

    @Published private(set) var projects: [Project] = []
    /// What `projects` answered, whole: the run profiles and other per-project fields ride along.
    @Published private(set) var raw: JSON = .null
    /// What waits for you and what is working across the projects, for the Findings tab's status and its badge.
    @Published private(set) var overview = SessionOverview([])
    /// The list has been read, from the saved copy or the server.
    @Published private(set) var loaded = false
    /// Why the last read of the projects failed.
    @Published private(set) var error: String?

    /// All cached project sessions, kept current by polling and the live stream.
    @Published private(set) var allSessions = AllSessions(sessions: [], projects: [])
    /// Every project's sessions have been read, from valid saved lists or the server.
    @Published private(set) var sessionsLoaded = false
    /// Why the last cross-project sessions read failed, including an unavailable route.
    @Published private(set) var sessionsError: String?

    private var generation = 0
    private var signOut: AnyCancellable?

    private init() {
        if let saved = Store.shared.cache.value("projects") { adopt(saved) }
        // Signing out (or a revoked token) empties the cache; what was read goes with it.
        signOut = Store.shared.$client.map { $0 != nil }.removeDuplicates().dropFirst().sink { connected in
            guard !connected else { return }
            MainActor.assumeIsolated { ProjectsModel.shared.reset() }
        }
    }

    private func adopt(_ answer: JSON) {
        guard let list = Project.parseList(answer) else { return }
        raw = answer
        if list != projects { projects = list }
        loaded = true
        recount()
    }
    private func reset() {
        generation += 1
        allSessions = AllSessions(sessions: [], projects: []); sessionsLoaded = false; sessionsError = nil
        projects = []; raw = .null; overview = SessionOverview([]); loaded = false; error = nil
    }

    func project(_ repo: String?) -> Project? { projects.first { $0.repo == repo } }

    /// The overview from what is saved of each project's conversations.
    func recount() {
        var all: [Session] = []
        var cachedRepos: Set<String> = []
        for p in projects {
            guard let list = Store.shared.cache.value("sessions:\(p.repo)").flatMap(Session.parseList) else { continue }
            cachedRepos.insert(p.repo)
            all += list
        }
        let list = AllSessions(sessions: all, projects: projects)
        if list != allSessions { allSessions = list }
        let loaded = list.cacheIsLoaded(projectsLoaded: Project.parseList(raw) != nil, cachedRepos: cachedRepos)
        if loaded != sessionsLoaded { sessionsLoaded = loaded }
        let overview = SessionOverview(all)
        if overview != self.overview { self.overview = overview }
    }

    /// `projects`, then every project's conversations in one call (for the counts), each project's handed to its feed.
    func load() async throws {
        generation += 1
        let mine = generation
        let answer: JSON
        do { answer = try await Store.shared.call("projects") }
        catch {
            guard mine == generation, !error.isCancellation else { throw error }
            self.error = errorText(error); loaded = true
            throw error
        }
        guard mine == generation else { return }
        adopt(answer)
        error = nil
        Store.shared.cache.store(answer, "projects")
        guard Store.shared.supports("sessions") else {
            sessionsError = AllSessions.unavailableMessage
            return
        }
        do {
            let all = try await Store.shared.call("sessions")
            guard mine == generation else { return }
            guard let items = Session.parseList(listOf(all, "sessions")) else { throw APIError(.nonJSON) }
            for p in projects { Store.shared.feed(p.repo).adopt(items.filter { $0.repo == p.repo }) }
            if !sessionsLoaded { sessionsLoaded = true }
            if sessionsError != nil { sessionsError = nil }
            recount()
        } catch {
            guard mine == generation, !error.isCancellation else { throw error }
            sessionsError = errorText(error)
            throw error
        }
    }
}
