// The Forge account and Slack workspace forms' fields and what a save sends, as the Windows client's screen_settings.c
// builds them: each form keeps the row it was filled from, the text of every box and the projects ticked. The tokens and
// the signing secret are write-only: the server never sends them back, so their boxes start empty and a save with one
// empty keeps the stored one.
import Foundation

/// Whether two project lists hold the same projects, in any order.
private func sameRepos(_ a: [String], _ b: [String]) -> Bool { a.count == b.count && a.allSatisfy(b.contains) }

/// What a Projects list offers: every project, then any ticked one that is no longer a project (the server refuses it on
/// save, so it stays visible to be unticked).
func settingsRepoChoices(projects: [String], ticked: [String]) -> [String] {
    var out: [String] = []
    for repo in projects + ticked where !repo.isEmpty && !out.contains(repo) { out.append(repo) }
    return out
}

// MARK: - Forge accounts

enum ForgeAccountField: Int, CaseIterable, Sendable {
    case label, organization, token
    var def: SettingsField {
        switch self {
        case .label: return SettingsField(key: "label", kind: .text, label: "Label", cue: "Acme production", hint: "Leave empty to name it after the organization.")
        case .organization: return SettingsField(key: "organization", kind: .text, label: "Organization", cue: "acme",
            hint: "The slug in your Forge URLs: forge.laravel.com/<organization>/…", mono: true)
        case .token: return SettingsField(key: "token", kind: .text, label: "API token", cue: "Paste a Forge API token",
            hint: "Create one in Forge under your profile's API tokens. The server stores it encrypted and never sends it back.", mono: true, secret: true)
        }
    }
    var key: String { def.key ?? "" }
    /// How much a box takes, as its edit's limit.
    var limit: Int { self == .token ? 4096 : 200 }
}

struct ForgeAccountFormState: Equatable, Sendable {
    /// What the form was filled from: the saved row or the defaults.
    var row: JSON
    var texts: [ForgeAccountField: String] = [:]
    /// The projects ticked, as `owner/name`.
    var repos: [String] = []
    var dirty = false

    init(row: JSON) { self.row = row.isObject ? row : [:]; fill() }

    /// A Forge account's id is, like an SSH server's, the time it was added in milliseconds.
    var id: Double { SSHServerFormState.rowID(row) }
    var hasToken: Bool { row["hasToken"].is(true) }
    func text(_ f: ForgeAccountField) -> String { texts[f] ?? "" }

    static func fieldText(_ row: JSON, _ f: ForgeAccountField) -> String { f == .token ? "" : row[f.key].string ?? "" }
    mutating func fill() {
        for f in ForgeAccountField.allCases { texts[f] = Self.fieldText(row, f) }
        repos = row["repos"].strings
        dirty = false
    }

    /// What the token's box says while it is empty: whether one is stored.
    var tokenCue: String { hasToken ? "Stored · type a new token to replace it" : ForgeAccountField.token.def.cue ?? "" }

    mutating func toggle(_ repo: String) {
        if let i = repos.firstIndex(of: repo) { repos.remove(at: i) } else { repos.append(repo) }
    }

    func body() -> Result<JSON, FormProblem> {
        var body: JSON = [:]
        for f in ForgeAccountField.allCases {
            let t = text(f).cTrimmed
            // An empty token is left out, so the stored one stays.
            if f != .token || !t.isEmpty { body[f.key] = .string(t) }
        }
        body["repos"] = JSON(repos)
        if (body["organization"].string ?? "").isEmpty { return .failure(FormProblem(message: "Enter the organization slug from your Forge URLs.")) }
        if !hasToken && (body["token"].string ?? "").isEmpty { return .failure(FormProblem(message: "Paste a Forge API token for this organization.")) }
        return .success(body)
    }

    /// Whether the form holds a change not saved yet, for the dot after the tab's title.
    var changed: Bool {
        !sameRepos(repos, row["repos"].strings) || ForgeAccountField.allCases.contains { text($0) != Self.fieldText(row, $0) }
    }

    /// The sidebar row's second line: the organization, and its one project or how many.
    static func sidebarLine(_ row: JSON) -> String {
        let org = row["organization"].nonEmpty ?? "", repos = row["repos"].items
        if repos.count == 1, let one = repos[0].string { return "\(org) · \(one)" }
        return "\(org) · \(repos.count) projects"
    }
    /// The header's subtitle for a saved account.
    static func subtitle(_ row: JSON) -> String {
        let n = row["repos"].count
        return "forge.laravel.com/\(row["organization"].nonEmpty ?? "") · \(n) project\(n == 1 ? "" : "s")\(row["hasToken"].is(true) ? "" : " · no token")"
    }
}

// MARK: - Slack workspaces

enum SlackWorkspaceField: Int, CaseIterable, Sendable {
    case label, token, signingSecret
    var def: SettingsField {
        switch self {
        case .label: return SettingsField(key: "label", kind: .text, label: "Label", cue: "Acme", hint: "Leave empty to name it after the workspace.")
        case .token: return SettingsField(key: "token", kind: .text, label: "User OAuth token", cue: "xoxp-…",
            hint: "The Slack app's User OAuth Token, under OAuth & Permissions once the app is installed to the workspace. Messages go out as the user who installed it, not as a bot. The server checks it with Slack, stores it encrypted and never sends it back.", mono: true, secret: true)
        case .signingSecret: return SettingsField(key: "signingSecret", kind: .text, label: "Signing secret", cue: "From the app's Basic Information",
            hint: "Lets the replies Slack sends to the Request URL below reach the sessions. Stored encrypted and never sent back.", mono: true, secret: true)
        }
    }
    var key: String { def.key ?? "" }
    var limit: Int { self == .label ? 200 : 4096 }
}

/// A project the workspace serves: the channels it may post to, as typed, whether it may write to people, and whether
/// each message waits for approval (`ask`) or goes at once (`allow`).
struct SlackProjectRule: Equatable, Sendable {
    var repo: String
    var channels = ""
    var directMessages = true
    var allow = false

    /// As the server takes it.
    var json: JSON {
        ["repo": .string(repo), "channels": JSON(SlackWorkspaceFormState.channels(from: channels)),
         "directMessages": .bool(directMessages), "permissionMode": .string(allow ? "allow" : "ask")]
    }
}

struct SlackWorkspaceFormState: Equatable, Sendable {
    /// The user token scopes the server's Slack tools call with.
    static let scopes = "chat:write, users:read, channels:read, groups:read, im:write, im:history, channels:history and groups:history"

    var row: JSON
    var texts: [SlackWorkspaceField: String] = [:]
    /// The projects ticked, in the order they were.
    var projects: [SlackProjectRule] = []
    var dirty = false

    init(row: JSON) { self.row = row.isObject ? row : [:]; fill() }

    /// A Slack workspace's id is also the time it was added in milliseconds.
    var id: Double { SSHServerFormState.rowID(row) }
    var hasToken: Bool { row["hasToken"].is(true) }
    var hasSigningSecret: Bool { row["hasSigningSecret"].is(true) }
    func text(_ f: SlackWorkspaceField) -> String { texts[f] ?? "" }
    func rule(_ repo: String) -> SlackProjectRule? { projects.first { $0.repo == repo } }

    static func fieldText(_ row: JSON, _ f: SlackWorkspaceField) -> String { f == .label ? row[f.key].string ?? "" : "" }

    /// The channels as the box shows them: `general, deploys`.
    static func channelsText(_ channels: JSON) -> String { channels.strings.filter { !$0.isEmpty }.joined(separator: ", ") }
    /// The channels a box holds, split on commas and spaces, without a leading `#`, each once, as the server keeps them.
    static func channels(from text: String) -> [String] {
        var out: [String] = []
        // Split on scalars: "\r\n" is one Character, and either half alone parts channels as well.
        for part in text.unicodeScalars.split(whereSeparator: { ", \t\r\n".unicodeScalars.contains($0) }) {
            let c = String(String.UnicodeScalarView(part.first == "#" ? part.dropFirst() : part[...]))
            if !c.isEmpty && !out.contains(c) { out.append(c) }
        }
        return out
    }
    /// The saved projects, read the way the form reads them back.
    static func savedRules(_ row: JSON) -> [SlackProjectRule] {
        var out: [SlackProjectRule] = []
        for p in row["projects"].items {
            guard let repo = p["repo"].nonEmpty, !out.contains(where: { $0.repo == repo }) else { continue }
            out.append(SlackProjectRule(repo: repo, channels: channelsText(p["channels"]), directMessages: !p["directMessages"].is(false),
                                        allow: p["permissionMode"].string == "allow"))
        }
        return out
    }

    mutating func fill() {
        for f in SlackWorkspaceField.allCases { texts[f] = Self.fieldText(row, f) }
        projects = Self.savedRules(row)
        dirty = false
    }

    /// What the token's and the secret's boxes say while they are empty: whether one is stored.
    func cue(_ f: SlackWorkspaceField) -> String {
        switch f {
        case .token where hasToken: return "Stored · paste a new token to replace it"
        case .signingSecret where hasSigningSecret: return "Stored · paste a new secret to replace it"
        default: return f.def.cue ?? ""
        }
    }

    /// Ticks or unticks a project. A new one starts on the server's defaults: no channels, direct messages allowed, every
    /// message asked about.
    mutating func toggle(_ repo: String) {
        if let i = projects.firstIndex(where: { $0.repo == repo }) { projects.remove(at: i) } else { projects.append(SlackProjectRule(repo: repo)) }
    }

    func body() -> Result<JSON, FormProblem> {
        var body: JSON = [:]
        for f in SlackWorkspaceField.allCases {
            let t = text(f).cTrimmed
            // An empty token or secret is left out, so the stored one stays.
            if f == .label || !t.isEmpty { body[f.key] = .string(t) }
        }
        body["projects"] = .array(projects.map(\.json))
        if !hasToken && (body["token"].string ?? "").isEmpty {
            return .failure(FormProblem(message: "Paste the Slack app's User OAuth Token (xoxp-…): messages go out as the user who installed the app."))
        }
        return .success(body)
    }

    /// Whether the form holds a change not saved yet, for the dot after the tab's title: the projects compared as the
    /// server would keep them, in any order.
    var changed: Bool {
        let now = projects.map(\.json), saved = Self.savedRules(row).map(\.json)
        if now.count != saved.count || !now.allSatisfy({ p in saved.contains { $0 == p } }) { return true }
        return SlackWorkspaceField.allCases.contains { text($0) != Self.fieldText(row, $0) }
    }

    /// The label of the other saved workspace that already serves `repo`, if one does: a project sends through one at most.
    func takenBy(_ repo: String, workspaces: [JSON]) -> String? {
        for w in workspaces where !(id != 0 && SSHServerFormState.rowID(w) == id) {
            if w["projects"].items.contains(where: { $0["repo"].string == repo }) { return w["label"].nonEmpty ?? "another" }
        }
        return nil
    }

    /// The sidebar row's second line: the workspace, and its one project or how many.
    static func sidebarLine(_ row: JSON) -> String {
        let team = row["team"].nonEmpty ?? "", projects = row["projects"].items
        if projects.count == 1, let one = projects[0]["repo"].string { return "\(team) · \(one)" }
        return "\(team) · \(projects.count) projects"
    }
    /// The header's subtitle for a saved workspace: the workspace, who it sends as, its projects, and what it lacks.
    static func subtitle(_ row: JSON) -> String {
        let n = row["projects"].count, projects = "\(n) project\(n == 1 ? "" : "s")"
        guard row["hasToken"].is(true) else { return "\(projects) · no token" }
        let user = row["user"].nonEmpty.map { " · as \($0)" } ?? ""
        return "\(row["team"].nonEmpty ?? "Slack")\(user) · \(projects)\(row["hasSigningSecret"].is(true) ? "" : " · no replies")"
    }
}
