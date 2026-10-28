// Reads remote host summaries and history; monitor credentials stay only in this screen's memory.
import Foundation
import Combine

@MainActor
final class SSHMonitoringModel: ObservableObject {
    let serverID: Double?
    @Published private(set) var servers: [SSHResourceServer] = []
    @Published private(set) var history: SSHResourceHistory?
    @Published private(set) var charts: [StatsChart] = []
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var uncertain = false
    @Published private(set) var error: String?
    @Published private(set) var credential: String?

    init(serverID: Double? = nil) { self.serverID = serverID }
    var available: Bool { Store.shared.supports("ssh_monitoring") }
    var server: SSHResourceServer? { servers.first { $0.id == serverID } }
    var canIssue: Bool { serverID != nil && Store.shared.supports("ssh_monitor_token") }
    var canRevoke: Bool { serverID != nil && Store.shared.supports("revoke_ssh_monitor_token") }
    var canToggle: Bool { server != nil && Store.shared.supports("update_ssh_server") }
    var title: String { server?.title ?? "SSH monitoring" }

    func load() async {
        guard available, !loading else { loaded = true; return }
        loading = true
        defer { loading = false }
        do {
            let answer = try await Store.shared.call("ssh_monitoring")
            guard answer["servers"].isArray else { throw APIError(.nonJSON) }
            servers = answer["servers"].items.compactMap(SSHResourceServer.init)
            if let serverID {
                guard server != nil else { history = nil; charts = []; throw APIError(.http, status: 404, message: "This server is no longer available.") }
                if Store.shared.supports("ssh_resources") {
                    let h = try await Store.shared.call("ssh_resources", ["id": .number(serverID)])
                    guard let parsed = SSHResourceHistory(h) else { throw APIError(.nonJSON) }
                    history = parsed; charts = parsed.charts
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
    func issueToken() { write("ssh_monitor_token") }
    func revokeToken() { write("revoke_ssh_monitor_token") }
    func toggleMonitoring() {
        guard let server else { return }
        write("update_ssh_server", extra: server.monitoringEdit)
    }
    private func write(_ operation: String, extra: JSON = [:]) {
        guard let serverID, !busy, !loading, !uncertain, Store.shared.supports(operation) else { return }
        busy = true; error = nil; credential = nil
        var args = extra; args["id"] = .number(serverID)
        Task {
            defer { busy = false }
            do {
                let answer = try await Store.shared.call(operation, args)
                if operation == "ssh_monitor_token" {
                    credential = try MonitorCredential(answer).configuration
                }
                await load()
            } catch {
                guard !error.isCancellation else { uncertain = true; return }
                self.error = errorText(error)
                uncertain = !((error as? APIError)?.isRefusal ?? false)
            }
        }
    }
    /// An uncertain token rotation is never resubmitted by polling or a retry button.
    func acknowledgeOutcome() { uncertain = false; Task { await load() } }
    func hideCredential() { credential = nil }
}
