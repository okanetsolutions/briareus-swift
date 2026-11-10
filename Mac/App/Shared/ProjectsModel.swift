// The projects the sidebar lists, for the screens that pick one (projects_list), and
// the ◉ Status overview of what waits for you and what is working.
// The sidebar owns the reading; other screens only read what it holds. It is screen_projects.c's ProjectsScreen state
// (projects_load, projects_count) and sessions_forget, kept here because the sidebar's views
// come and go (Settings takes the sidebar's place) while the Windows client's screens stay on their pane's stack.
import Combine
import Foundation

@MainActor
final class ProjectsModel: ObservableObject {
    static let shared = ProjectsModel()

    @Published var projects: [Project] = []
    /// What `projects` answered, whole: the run profiles and other per-project fields ride along.
    @Published var raw: JSON = .null
    /// Per project (by repo): how many conversations, and whether one is working.
    @Published private(set) var counts: [String: Int] = [:]
    @Published private(set) var busy: [String: Bool] = [:]
    /// What waits for you and what is working across the projects, for ◉ Status and its badge.
    @Published private(set) var overview = SessionOverview([])
    /// The list has been read, from the saved copy or the server.
    @Published private(set) var loaded = false
    /// Why the last read of the projects failed.
    @Published private(set) var error: String?
    /// The project screen pushed inside the sidebar (sessions_screen_new), nil on the projects list.
    @Published var openProject: SidebarSessions?

    /// Why the last cross-project sessions read failed, including an unavailable route.
    @Published private(set) var sessionsError: String?

    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var signOut: AnyCancellable?
    private var recountTask: Task<Void, Never>?
    /// Each project's saved conversations, parsed once: every save of them goes through here.
    let saved = SavedSessionLists(cache: Store.shared.cache)

    private init() {
        if let saved = Store.shared.cache.value("projects") { adopt(saved); recount() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .sessionForgotten, object: nil, queue: .main) { note in
            let repo = note.userInfo?["repo"] as? String, id = note.userInfo?["id"] as? String
            MainActor.assumeIsolated { ProjectsModel.shared.forget(repo: repo, id: id) }
        })
        observers.append(center.addObserver(forName: .projectsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = Task { await ProjectsModel.shared.load() } }
        })
        observers.append(center.addObserver(forName: .sessionsChanged, object: nil, queue: .main) { note in
            let repo = note.userInfo?["repo"] as? String
            MainActor.assumeIsolated {
                let model = ProjectsModel.shared
                if let open = model.openProject, repo == nil || repo == open.project.repo { Task { await open.load() } }
                model.recount()
            }
        })
        // Signing out (or a revoked token) empties the cache; what was read goes with it.
        signOut = Store.shared.$client.map { $0 != nil }.removeDuplicates().dropFirst().sink { connected in
            guard !connected else { return }
            MainActor.assumeIsolated { ProjectsModel.shared.reset() }
        }
    }

    func adopt(_ answer: JSON) {
        guard let list = Project.parseList(answer) else { return }
        if raw != answer { raw = answer }
        if projects != list { projects = list }
        if !loaded { loaded = true }
    }

    private func reset() {
        generation += 1
        recountTask?.cancel(); recountTask = nil
        saved.reset()
        sessionsError = nil
        projects = []; raw = .null; counts = [:]; busy = [:]; overview = SessionOverview([])
        loaded = false; error = nil; openProject = nil
    }

    /// Catch-up delivers every session separately; rebuild the counts, dots and overview once per burst.
    func scheduleRecount() {
        guard recountTask == nil else { return }
        recountTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.recount()
        }
    }

    /// projects_count: what the saved lists say about each project's conversations.
    func recount() {
        recountTask?.cancel(); recountTask = nil
        // The lists live records changed are saved here, once per burst rather than once per record.
        saved.saveChanges()
        var counts: [String: Int] = [:], busy: [String: Bool] = [:]
        var all: [Session] = []
        for p in projects {
            guard let sessions = saved.list(p.repo) else { continue }
            counts[p.repo] = sessions.count
            busy[p.repo] = sessions.contains { $0.isActive }
            all += sessions
        }
        if counts != self.counts { self.counts = counts }
        if busy != self.busy { self.busy = busy }
        let overview = SessionOverview(all)
        if overview != self.overview { self.overview = overview }
    }

    /// projects_load: the saved list at once the first time, then `projects` and every project's conversations (for the
    /// counts and the dots), each project's rows saved under its own key. Nil on success, else the error.
    @discardableResult
    func load() async -> APIError? {
        if !loaded, let saved = Store.shared.cache.value("projects") { adopt(saved); recount() }
        generation += 1
        let mine = generation
        let answer: JSON
        do {
            answer = try await Store.shared.call("projects")
        } catch {
            guard mine == generation, !error.isCancellation else { return nil }
            self.error = errorText(error)
            loaded = true
            return error as? APIError
        }
        guard mine == generation else { return nil }
        adopt(answer)
        if error != nil { error = nil }
        Store.shared.cache.store(answer, "projects")
        recount()
        // The approvals agents wait on count on the ◉ too.
        _ = await AttentionModel.shared.load()
        guard mine == generation else { return nil }
        guard Store.shared.supports("sessions") else {
            sessionsError = SessionOverview.unavailableMessage
            return nil
        }
        do {
            let all = try await Store.shared.call("sessions")
            guard mine == generation else { return nil }
            guard let items = Session.parseList(all) else { throw APIError(.nonJSON) }
            for p in projects {
                saved.save(items.filter { $0.repo == p.repo }, repo: p.repo)
            }
            if sessionsError != nil { sessionsError = nil }
            recount()
            return nil
        } catch {
            guard mine == generation, !error.isCancellation else { return nil }
            sessionsError = errorText(error)
            recount()
            return error as? APIError
        }
    }

    /// sessions_forget: a deleted conversation leaves the saved list, its transcript, and the list on screen right away, which
    /// then asks the server again in case the list changed in other ways too.
    func forget(repo: String?, id: String?) {
        guard let repo, !repo.isEmpty, let id, !id.isEmpty else { return }
        _ = saved.remove(id, repo: repo)
        Store.shared.cache.remove("transcript:\(id)")
        scheduleRecount()
        guard let open = openProject, open.project.repo == repo else { return }
        open.drop(id)
        Task { await open.load() }
    }

    func project(_ repo: String?) -> Project? { projects.first { $0.repo == repo } }
}

// MARK: - Live

/// Every session the token can see, followed on one connection (core events.stream): a record lands as it changes and a
/// deleted one goes, in the saved per-project lists, the counts and dots, and the open project's list, so the sidebar
/// keeps up without its 7-second poll. The stream starts with every session as it stands; nothing is replayed after a
/// drop, so polling carries on, every minute while the stream flows.
@MainActor
final class SessionFeed: ObservableObject {
    static let shared = SessionFeed()
    @Published private(set) var live = false
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil, Store.shared.supports("events") else { return }
        task = Task { await follow() }
    }
    func stop() { task?.cancel(); task = nil; live = false }

    private func follow() async {
        var failures = 0
        while !Task.isCancelled {
            guard let client = Store.shared.client, Store.shared.active else { try? await Task.sleep(nanoseconds: 2_000_000_000); continue }
            do {
                try await client.stream("events", opened: { Task { @MainActor in SessionFeed.shared.live = true } }) { event, data in
                    guard let j = JSON.parse(data) else { return }
                    Task { @MainActor in SessionFeed.shared.apply(event, j) }
                }
                failures = 0
            } catch {
                live = false
                if Task.isCancelled || (error as? APIError)?.kind == .cancelled { return }
                if let s = (error as? APIError)?.status, s == 401 || s == 403 || s == 404 { task = nil; return }
                failures = min(failures + 1, 6)
            }
            live = false
            try? await Task.sleep(nanoseconds: UInt64(min(pow(2, Double(failures)), 60) * 1_000_000_000))
        }
    }

    private func apply(_ event: String, _ j: JSON) {
        let cache = Store.shared.cache
        switch SessionsEvent(event, j) {
        case .session(let s)?:
            guard let repo = s.repo else { return }
            if ProjectsModel.shared.saved.upsert(s, repo: repo) != nil { ProjectsModel.shared.scheduleRecount() }
            post(.sessionLive, ["repo": repo, "session": s.raw])
        case .deleted(let id)?:
            for p in ProjectsModel.shared.projects {
                let saved = ProjectsModel.shared.saved.remove(id, repo: p.repo)
                guard saved != nil || ProjectsModel.shared.openProject?.project.repo == p.repo else { continue }
                cache.remove("transcript:\(id)")
                post(.sessionForgotten, ["id": id, "repo": p.repo])
            }
        case nil: return
        }
    }
}
