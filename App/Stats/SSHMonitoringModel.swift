// Reads remote host summaries and history; monitor credentials stay only in this screen's memory.
import Foundation
import Combine

@MainActor
final class SSHMonitoringModel: ObservableObject {
    let serverID: Double?
    @Published private(set) var servers: [SSHResourceServer] = []
    @Published private(set) var charts: [StatsChart] = []
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var uncertain = false
    @Published private(set) var error: String?
    @Published private(set) var credential: String?

    init(serverID: Double? = nil) { self.serverID = serverID }
    private var capabilities: SSHMonitoringCapabilities {
        SSHMonitoringCapabilities(serverID: serverID, server: server, supports: Store.shared.supports)
    }
    var available: Bool { capabilities.available }
    var server: SSHResourceServer? { servers.first { $0.id == serverID } }
    var canIssue: Bool { capabilities.canIssue }
    var canRevoke: Bool { capabilities.canRevoke }
    var canToggle: Bool { capabilities.canToggle }
    var title: String { server?.title ?? "SSH monitoring" }

    func load(afterWrite: Bool = false) async {
        guard available else { loaded = true; return }
        guard SSHMonitoringPolicy.canLoad(loading: loading, busy: busy, afterWrite: afterWrite) else { return }
        loading = true
        defer { loading = false }
        do {
            let answer = try await Store.shared.call("ssh_monitoring")
            servers = try SSHResourceServer.parseList(answer)
            if let serverID {
                guard server != nil else { charts = []; throw APIError(.http, status: 404, message: "This server is no longer available.") }
                if Store.shared.supports("ssh_resources") {
                    let h = try await Store.shared.call("ssh_resources", ["id": .number(serverID)])
                    guard let parsed = SSHResourceHistory(h) else { throw APIError(.nonJSON) }
                    charts = parsed.charts
                }
            }
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
            try? await Task.sleep(for: .seconds(60))
        }
    }
    func issueToken() { write(.issue) }
    func revokeToken() { write(.revoke) }
    func toggleMonitoring() {
        guard let server else { return }
        write(.toggle, extra: server.monitoringEdit)
    }
    private func write(_ action: SSHMonitoringAction, extra: JSON = [:]) {
        let operation = action.rawValue
        guard let serverID, SSHMonitoringPolicy.canWrite(serverID: serverID, supported: Store.shared.supports(operation), loading: loading, busy: busy, uncertain: uncertain) else { return }
        busy = true; error = nil
        if action.clearsCredential { credential = nil }
        let args = action.body(serverID: serverID, extra: extra)
        Task {
            defer { busy = false }
            do {
                let answer = try await Store.shared.call(operation, args)
                credential = try action.credential(from: answer, current: credential)
                await load(afterWrite: true)
            } catch {
                uncertain = SettingsWritePolicy.isUncertain(error)
                guard !error.isCancellation else { return }
                self.error = errorText(error)
            }
        }
    }
    /// An uncertain token rotation is never resubmitted by polling or a retry button.
    func acknowledgeOutcome() { uncertain = false; Task { await load() } }
    func hideCredential() { credential = nil }
}
