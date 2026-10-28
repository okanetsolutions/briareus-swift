// Exercise real feature models with controlled responses; no network or credentials leave this process.
import Foundation

@MainActor
final class Store {
    static let shared = Store()
    var offered = Set(APIRoute.all.map(\.name))
    var calls: [(String, JSON)] = []
    var respond: (String, JSON) async throws -> JSON = { _, _ in [:] }
    func supports(_ name: String) -> Bool { offered.contains(name) }
    func call(_ name: String, _ args: JSON = [:]) async throws -> JSON {
        calls.append((name, args)); return try await respond(name, args)
    }
}
func errorText(_ error: Error) -> String { String(describing: error) }
extension Error {
    var isCancellation: Bool { (self as? APIError)?.kind == .cancelled || self is CancellationError }
}

@main
struct ClientUpdatesCheck {
    @MainActor
    static func settled(_ busy: () -> Bool) async {
        for _ in 0..<1000 {
            if !busy() { return }
            await Task.yield()
        }
        preconditionFailure("Model did not settle")
    }
    @MainActor
    static func main() async throws {
        let store = Store.shared
        store.respond = { name, _ in
            switch name {
            case "my_github": return ["connected": false]
            case "connect_github": return ["connected": true, "login": "alice"]
            default: preconditionFailure("Unexpected personal connection request")
            }
        }
        let personal = PersonalConnectionModel(kind: .github)
        await personal.load()
        precondition(personal.status?.connected == false)
        personal.token = "one-time-token"
        personal.save(); personal.save()
        await settled { personal.busy }
        precondition(personal.status?.identity == "alice" && personal.token.isEmpty)
        precondition(store.calls.filter { $0.0 == "connect_github" }.count == 1)
        store.respond = { _, _ in throw APIError(.network, message: "Connection lost") }
        personal.token = "replacement-token"; personal.save()
        await settled { personal.busy }
        precondition(personal.uncertain && personal.token.isEmpty)
        let count = store.calls.count
        personal.token = "not-resubmitted"; personal.save()
        precondition(store.calls.count == count)

        store.calls = []
        store.respond = { name, args in
            switch name {
            case "users": return ["users": [["id": 1, "name": "Admin", "role": "admin"], ["id": 2, "name": "Member", "role": "member"]]]
            case "shares": return ["shares": [["kind": "project", "id": "5", "userId": 2]]]
            case "settings_projects": return ["projects": [["id": 5, "repo": "o/r"], ["id": 6, "repo": "o/other"]]]
            case "update_shares": return args
            default: preconditionFailure("Unexpected sharing request")
            }
        }
        let sharing = SharingModel()
        await sharing.load()
        precondition(sharing.loaded && sharing.picked == [2])
        sharing.toggle(sharing.users[1])
        precondition(sharing.dirty && sharing.picked.isEmpty)
        sharing.selectResource("6")
        precondition(sharing.resourceID == "5")
        sharing.save(); sharing.save()
        await settled { sharing.busy }
        precondition(!sharing.dirty && sharing.picked.isEmpty)
        precondition(store.calls.filter { $0.0 == "update_shares" }.count == 1)
        precondition(store.calls.last?.1 == ["kind": "project", "id": "5", "userIds": []])
        sharing.selectResource("6"); sharing.selectResource("5")
        precondition(sharing.picked.isEmpty)

        store.calls = []
        store.respond = { name, _ in
            switch name {
            case "ssh_monitoring": return ["servers": [["id": 123, "label": "Host", "repo": "o/r", "enabled": true, "monitoringEnabled": true, "stale": true]]]
            case "ssh_resources": return ["serverId": 123, "intervalSeconds": 60, "samples": []]
            case "ssh_monitor_token": return ["serverId": 123, "endpoint": "https://example.test/telemetry", "token": "one-time-token", "intervalSeconds": 60]
            default: preconditionFailure("Unexpected monitoring request")
            }
        }
        let monitor = SSHMonitoringModel(serverID: 123)
        await monitor.load()
        monitor.issueToken(); monitor.issueToken()
        await settled { monitor.busy }
        precondition(monitor.credential?.contains("one-time-token") == true)
        precondition(store.calls.filter { $0.0 == "ssh_monitor_token" }.count == 1)
        monitor.hideCredential(); precondition(monitor.credential == nil)
        store.respond = { _, _ in throw APIError(.network) }
        monitor.issueToken()
        await settled { monitor.busy }
        precondition(monitor.uncertain)
        let writes = store.calls.count
        monitor.issueToken()
        precondition(store.calls.count == writes)
        print("Client update model checks passed")
    }
}
