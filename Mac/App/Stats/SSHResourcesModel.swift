// SSH telemetry state: poll visible server summaries and the selected server's persistent history.
import SwiftUI

@MainActor
final class SSHResourcesModel: ObservableObject {
    @Published private(set) var servers: [SSHResourceServer] = []
    @Published var selectedID = "" { didSet { if oldValue != selectedID { reading = nil; historyError = nil; historyLoaded = false } } }
    @Published private(set) var reading: SSHResourceReading?
    @Published private(set) var error: String?
    @Published private(set) var historyError: String?
    @Published private(set) var loaded = false
    @Published private(set) var historyLoaded = false
    var available: Bool { Store.shared.supports("ssh_resource_servers") && Store.shared.supports("ssh_resources") }
    var selected: SSHResourceServer? { servers.first { $0.id == selectedID } }

    func loadServers() async -> APIError? {
        guard available else { loaded = true; return nil }
        let client = Store.shared.client
        do {
            let answer = try await Store.shared.call("ssh_resource_servers")
            guard !Task.isCancelled, client === Store.shared.client else { return nil }
            guard let rows = SSHResourceServer.list(answer) else { throw APIError(.nonJSON) }
            servers = rows
            selectedID = SSHResourceServer.selection(selectedID, in: rows)
            error = nil; loaded = true
            return nil
        } catch {
            guard !error.isCancellation, client === Store.shared.client else { return nil }
            self.error = errorText(error); loaded = true
            return error as? APIError
        }
    }
    func loadHistory() async -> APIError? {
        let id = selectedID, client = Store.shared.client
        guard available, !id.isEmpty else { return nil }
        do {
            let answer = try await Store.shared.call("ssh_resources", ["id": .string(id)])
            guard !Task.isCancelled, selectedID == id, client === Store.shared.client else { return nil }
            guard let result = SSHResourceReading(answer) else { throw APIError(.nonJSON) }
            reading = result; historyError = nil; historyLoaded = true
            return nil
        } catch {
            guard !error.isCancellation, selectedID == id, client === Store.shared.client else { return nil }
            historyError = errorText(error); historyLoaded = true
            return error as? APIError
        }
    }
    func followServers() async { await poll(every: 60) { await self.loadServers() } }
    func followHistory() async { await poll(every: 60) { await self.loadHistory() } }
    func reload() async { _ = await loadServers(); _ = await loadHistory() }
}
