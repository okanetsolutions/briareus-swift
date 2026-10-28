// The caller's personal integrations; tokens are write-only and never cached by the client.
import Foundation

enum PersonalConnectionKind: String, CaseIterable, Sendable, Identifiable {
    case github, homeAssistant
    var id: String { rawValue }
    var title: String { self == .github ? "My GitHub account" : "My Home Assistant" }
    var read: String { self == .github ? "my_github" : "my_home_assistant" }
    var connect: String { self == .github ? "connect_github" : "connect_home_assistant" }
    var disconnect: String { self == .github ? "disconnect_github" : "disconnect_home_assistant" }
    var explanation: String {
        self == .github
            ? "Comments, merges, labels and your sessions’ Git operations use your account. Disconnecting restores the server’s GitHub identity."
            : "Connect your own Home Assistant using its address and a long-lived access token."
    }
    func body(token: String, url: String) throws -> JSON {
        let token = token.cTrimmed
        guard !token.isEmpty else { throw APIError(.http, status: 400, message: "Enter an access token.") }
        var body: JSON = ["token": .string(token)]
        if self == .homeAssistant {
            let address = url.cTrimmed
            guard let parsed = URL(string: address), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""),
                  parsed.host != nil, parsed.user == nil, parsed.password == nil else {
                throw APIError(.http, status: 400, message: "Enter an HTTP or HTTPS Home Assistant address without credentials.")
            }
            body["url"] = .string(address)
        }
        return body
    }
}

struct PersonalConnectionStatus: Equatable, Sendable {
    let connected: Bool
    let identity: String?
    let url: String
    init?(_ raw: JSON) {
        guard let connected = raw["connected"].bool else { return nil }
        self.connected = connected
        identity = raw["login"].nonEmpty
        url = raw["url"].string ?? ""
    }
    var summary: String { connected ? identity.map { "Connected as @\($0)" } ?? "Connected" : "Not connected" }
}

/// The input and saved status are separate, so a refresh never overwrites edits made while it was in flight.
struct PersonalConnectionFormState: Equatable, Sendable {
    var token = ""
    var url = ""
    var status: PersonalConnectionStatus?
    var dirty: Bool { !token.isEmpty || url != (status?.url ?? "") }
    var canSave: Bool { status != nil && !token.cTrimmed.isEmpty }
    func canSave(supported: Bool, busy: Bool, uncertain: Bool) -> Bool {
        canSave && SettingsWritePolicy.allows(supported: supported, busy: busy, uncertain: uncertain)
    }
    func canDisconnect(supported: Bool) -> Bool { status?.connected == true && supported }
    /// Reconciliation clears secrets but keeps the address so a failed connection can be corrected.
    mutating func checkOutcome() { token = "" }
    mutating func adopt(_ status: PersonalConnectionStatus, preservingEdits: Bool) {
        let preserve = preservingEdits && dirty
        self.status = status
        if !preserve { token = ""; url = status.url }
    }
    mutating func discard() { token = ""; url = status?.url ?? "" }
}
