// Administrative sharing: save the complete membership of one resource without changing another.
import Foundation

enum ShareKind: String, CaseIterable, Identifiable, Sendable {
    case project, dbServer, sshServer, mcpServer, forgeAccount, envoyerAccount
    var id: String { rawValue }
    var title: String {
        switch self {
        case .project: return "Projects"
        case .dbServer: return "Database servers"
        case .sshServer: return "SSH servers"
        case .mcpServer: return "MCP servers"
        case .forgeAccount: return "Forge accounts"
        case .envoyerAccount: return "Envoyer accounts"
        }
    }
    var operation: String {
        switch self {
        case .project: return "settings_projects"
        case .dbServer: return "settings_db_servers"
        case .sshServer: return "settings_ssh_servers"
        case .mcpServer: return "settings_mcp_servers"
        case .forgeAccount: return "settings_forge_accounts"
        case .envoyerAccount: return "settings_envoyer_accounts"
        }
    }
    var listKey: String {
        switch self {
        case .project: return "projects"
        case .dbServer, .sshServer, .mcpServer: return "servers"
        case .forgeAccount, .envoyerAccount: return "accounts"
        }
    }
    func body(resourceID: String, users: Set<Int>) -> JSON {
        ["kind": .string(rawValue), "id": .string(resourceID), "userIds": .array(users.sorted().map { JSON($0) })]
    }
    func members(_ shares: JSON, resourceID: String) -> Set<Int> {
        Set(shares.items.filter { $0["kind"].string == rawValue && $0["id"].string == resourceID }.compactMap { $0["userId"].int })
    }
}

struct SharingUser: Equatable, Sendable, Identifiable {
    let id: Int
    let name: String
    let admin: Bool
    let disabled: Bool
    init?(_ raw: JSON) {
        guard let id = raw["id"].int, id > 0, let name = raw["name"].string else { return nil }
        self.id = id; self.name = name
        admin = raw["role"].string == "admin"
        disabled = raw["disabled"].is(true)
    }
    var detail: String { disabled ? "Disabled" : admin ? "Admin · already has access" : "Member" }
}

struct ShareResource: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    init?(_ raw: JSON) {
        if let id = raw["id"].string { self.id = id }
        else if let id = raw["id"].number, id > 0, id.isFinite { self.id = String(format: "%.0f", id) }
        else { return nil }
        title = raw["label"].nonEmpty ?? raw["repo"].nonEmpty ?? raw["name"].nonEmpty ?? raw["host"].nonEmpty ?? id
    }
}
