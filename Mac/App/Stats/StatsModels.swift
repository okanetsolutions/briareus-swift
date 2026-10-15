// The Resources screens' state: a session's stats (`session_stats`) and the server's with its open sessions
// (`server_stats`, `sessions_stats`), each read again as often as the server samples while its screen is open. What the
// figures say is StatsLogic's.
import Foundation

@MainActor
final class SessionStatsModel: ObservableObject {
    let sessionID: String
    @Published private(set) var reading: SessionStatsReading?
    /// The last read failed; the figures already on screen stay.
    @Published private(set) var error: String?
    @Published private(set) var loaded = false

    init(sessionID: String) { self.sessionID = sessionID }

    var available: Bool { Store.shared.supports("session_stats") }

    func load() async {
        guard available else { loaded = true; return }
        do {
            let answer = try await Store.shared.call("session_stats", ["sessionId": .string(sessionID)])
            guard let reading = SessionStatsReading(answer) else { throw APIError(.nonJSON) }
            self.reading = reading
            error = nil
        } catch {
            guard !error.isCancellation else { return }
            self.error = errorText(error)
        }
        loaded = true
    }

    /// Reads now, then again every sampling interval until the screen goes.
    func follow() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(statsPollSeconds(reading?.host)))
        }
    }
}

@MainActor
final class ServerStatsModel: ObservableObject {
    @Published private(set) var server: ServerStats?
    /// The open sessions, the busiest first, named by the conversations the sidebar has read.
    @Published private(set) var rows: [StatsRow] = []
    @Published private(set) var error: String?
    @Published private(set) var loaded = false

    var available: Bool { Store.shared.supports("server_stats") }
    var listsSessions: Bool { Store.shared.supports("sessions_stats") }

    private var knownSessions: [Session] {
        ProjectsModel.shared.projects.flatMap { p in
            Store.shared.cache.value("sessions:\(p.repo)").flatMap(Session.parseList) ?? []
        }
    }

    func load() async {
        guard available else { loaded = true; return }
        let lists = listsSessions
        async let serverAnswer = Store.shared.call("server_stats")
        async let openAnswer: JSON? = lists ? Store.shared.call("sessions_stats") : nil
        do {
            let (s, o) = try await (serverAnswer, openAnswer)
            guard let parsed = ServerStats(s) else { throw APIError(.nonJSON) }
            server = parsed
            let titles = Dictionary(knownSessions.map { ($0.id, $0.displayTitle) }) { a, _ in a }
            rows = o.flatMap(OpenSessionsStats.init)?.rows(titles: titles) ?? []
            error = nil
        } catch {
            guard !error.isCancellation else { return }
            self.error = errorText(error)
        }
        loaded = true
    }

    func follow() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(statsPollSeconds(server?.host)))
        }
    }

    /// A row opens that session's own stats.
    func open(_ row: StatsRow) {
        let raw = knownSessions.first { $0.id == row.id }?.raw ?? ["id": .string(row.id), "title": .string(row.title)]
        Navigator.shared.push(.sessionStats(session: raw))
    }
}
