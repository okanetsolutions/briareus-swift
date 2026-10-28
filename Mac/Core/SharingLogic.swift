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

/// Membership is replaced as one complete set; selecting another resource must never carry edits across it.
struct SharingFormState: Equatable, Sendable {
    var picked: Set<Int> = []
    var original: Set<Int> = []
    var dirty: Bool { picked != original }
    mutating func select(_ members: Set<Int>) { original = members; picked = members }
    mutating func toggle(_ id: Int) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }
    mutating func discard() { picked = original }
    func membership(for userID: Int) -> ShareMembership { picked.contains(userID) ? .shared : .notShared }
}

enum ShareMembership: Equatable, Sendable {
    case shared, notShared
    var title: String { self == .shared ? "Shared" : "Not shared" }
}

/// A save replaces only the addressed resource's grants and retains grants on every other resource.
struct SharingUpdate: Equatable, Sendable {
    let members: Set<Int>
    let shares: JSON
    init(_ answer: JSON, kind: ShareKind, resourceID: String, previous: JSON) throws {
        guard answer["kind"].string == kind.rawValue, answer["id"].string == resourceID,
              let ids = answer["userIds"].array else { throw APIError(.nonJSON) }
        let parsed = ids.compactMap(\.int)
        guard parsed.count == ids.count, parsed.allSatisfy({ $0 > 0 }) else { throw APIError(.nonJSON) }
        members = Set(parsed)
        let kept = previous.items.filter { $0["kind"].string != kind.rawValue || $0["id"].string != resourceID }
        shares = .array(kept + members.sorted().map { ["kind": .string(kind.rawValue), "id": .string(resourceID), "userId": JSON($0)] })
    }
}
