// The Resources screens' state: a session's stats (`session_stats`) and the server's with its open sessions
// (`server_stats`, `sessions_stats`), each read again as often as the server samples while its screen is open, as the
// Mac's. What the figures say is StatsLogic's.
import Combine
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
    @Published var tab: ServerDashboardTab = .overview
    @Published var monitoredServerID: Double?
    @Published private(set) var server: ServerStats?
    @Published private(set) var rows: [StatsRow] = []
    @Published private(set) var charts: [StatsChart] = []
    @Published private(set) var serverError: String?
    @Published private(set) var sessionsError: String?
    @Published private(set) var sessionsLoaded = false

    var tabs: [ServerDashboardTab] { ServerDashboardTab.available(supports: Store.shared.supports) }
    var error: String? { tab.error(server: serverError, sessions: sessionsError) }
    private var requests: [String: UUID] = [:]
    private var sessionsHost: HostStats?
    private var known: KnownSessions { KnownSessions(repos: ProjectsModel.shared.projects.map(\.repo), cache: Store.shared.cache) }

    /// Only the selected panel reads; a slow or failed session list cannot block the overview.
    func load() async {
        guard let operation = tab.operation, Store.shared.supports(operation), !Task.isCancelled else { return }
        let request = UUID()
        requests[operation] = request
        defer { if requests[operation] == request { requests[operation] = nil } }
        do {
            let answer = try await Store.shared.call(operation)
            guard requests[operation] == request, Store.shared.supports(operation), !Task.isCancelled else { return }
            if operation == "sessions_stats" {
                guard let parsed = OpenSessionsStats(answer) else { throw APIError(.nonJSON) }
                rows = parsed.rows(known: known)
                sessionsHost = parsed.host
                sessionsLoaded = true
                sessionsError = nil
            } else {
                guard let parsed = ServerStats(answer) else { throw APIError(.nonJSON) }
                server = parsed
                charts = parsed.charts
                serverError = nil
            }
        } catch {
            guard requests[operation] == request, Store.shared.supports(operation), !Task.isCancelled, !error.isCancellation else { return }
            if operation == "sessions_stats" { sessionsError = errorText(error) }
            else { serverError = errorText(error) }
        }
    }

    func follow() async {
        while !Task.isCancelled {
            discardUnsupportedReadings()
            guard let supported = tab.resolved(in: tabs) else { return }
            if supported != tab { tab = supported; return }
            guard tab.operation != nil else { return }
            await load()
            guard tabs.contains(tab) else { continue }
            do { try await Task.sleep(for: .seconds(tab.pollSeconds(server: server?.host, sessions: sessionsHost))) }
            catch { return }
        }
    }

    private func discardUnsupportedReadings() {
        if !Store.shared.supports("server_stats") {
            requests["server_stats"] = nil
            server = nil
            charts = []
            serverError = nil
        }
        if !Store.shared.supports("sessions_stats") {
            requests["sessions_stats"] = nil
            rows = []
            sessionsHost = nil
            sessionsLoaded = false
            sessionsError = nil
        }
    }

    /// The record a row opens its session's Resources with: the conversation's as the feeds hold it, else its id and name.
    func record(_ row: StatsRow) -> JSON {
        known.record(row)
    }
}
