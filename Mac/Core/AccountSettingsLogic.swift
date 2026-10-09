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

// MARK: - MCP servers

/// An MCP server's boxes (core #124; the Windows client's core/mcp.c): its name and label, a remote endpoint or a command
/// with its arguments, the write-only headers or environment, and the OAuth client it signs in as.
enum McpServerField: Int, CaseIterable, Sendable {
    case name, label, url, command, args, headers, env, oauthClientId, oauthClientSecret, oauthScope, oauthClientName
    var def: SettingsField {
        switch self {
        case .name: return SettingsField(key: "name", kind: .text, label: "Tool name", cue: "linear",
            hint: "What its tools are filed under (mcp__<name>__…): letters, digits, _ and -.", mono: true)
        case .label: return SettingsField(key: "label", kind: .text, label: "Label", cue: "Linear", hint: "Leave empty to show the tool name.")
        case .url: return SettingsField(key: "url", kind: .text, label: "Endpoint", cue: "https://mcp.example.com/mcp",
            hint: "The server's Streamable HTTP address: https, or http on the Briareus machine itself.", mono: true)
        case .command: return SettingsField(key: "command", kind: .text, label: "Command", cue: "npx",
            hint: "What starts it beside each session, on the Briareus machine.", mono: true)
        case .args: return SettingsField(key: "args", kind: .list, label: "Arguments", cue: "-y\n@modelcontextprotocol/server-everything",
            hint: "One per line.", rows: 3, mono: true)
        case .headers: return SettingsField(key: "headers", kind: .area, label: "Headers", cue: "Authorization: Bearer …",
            hint: "One per line, Name: value. Stored encrypted and never sent back; what you type replaces the stored set. An Authorization header means no OAuth sign-in.", rows: 3, mono: true, secret: true)
        case .env: return SettingsField(key: "env", kind: .area, label: "Environment", cue: "API_KEY=…",
            hint: "One per line, NAME=value. Stored encrypted and never sent back; what you type replaces the stored set.", rows: 3, mono: true, secret: true)
        case .oauthClientId: return SettingsField(key: "oauthClientId", kind: .text, label: "OAuth client id", cue: "Registered automatically",
            hint: "For a server that does not let clients register themselves.", mono: true)
        case .oauthClientSecret: return SettingsField(key: "oauthClientSecret", kind: .text, label: "OAuth client secret", cue: "None",
            hint: "That client's secret. Stored encrypted and never sent back.", mono: true, secret: true)
        case .oauthScope: return SettingsField(key: "oauthScope", kind: .text, label: "OAuth scopes", cue: "What the server asks for", mono: true)
        case .oauthClientName: return SettingsField(key: "oauthClientName", kind: .text, label: "Client name", cue: "Briareus",
            hint: "The name Briareus registers under, for a server that only lets clients it knows register.")
        }
    }
    var key: String { def.key ?? "" }
    var limit: Int {
        switch self {
        case .name: return 64
        case .label: return 200
        case .url: return 2048
        case .command, .oauthScope, .oauthClientSecret: return 1024
        case .oauthClientId: return 256
        case .oauthClientName: return 100
        case .args, .headers, .env: return 64 * 1024
        }
    }
    /// Write-only: the box starts empty and, left empty, keeps what is stored.
    var isSecret: Bool { self == .headers || self == .env || self == .oauthClientSecret }
}

struct McpServerFormState: Equatable, Sendable {
    /// Names Briareus's own tools use.
    static let reserved = ["reviewer_memory", "reviewer_ssh", "reviewer_slack", "reviewer_workers", "browser"]

    var row: JSON
    var texts: [McpServerField: String] = [:]
    var stdio = false
    var loopback = false
    var enabled = true
    /// The projects ticked; none means every project.
    var repos: [String] = []
    /// The stored headers, environment or client secret to remove on save.
    var clear: Set<McpServerField> = []
    var dirty = false

    init(row: JSON) { self.row = row.isObject ? row : [:]; fill() }

    var id: Double {
        guard let n = row["id"].number, n.isFinite, n > 0, n == n.rounded() else { return 0 }
        return n
    }
    func text(_ f: McpServerField) -> String { texts[f] ?? "" }

    static func fieldText(_ row: JSON, _ f: McpServerField) -> String {
        if f.isSecret { return "" }
        if f == .args { return SettingsText.listText(row["args"]) }
        return row[f.key].string ?? ""
    }
    mutating func fill() {
        for f in McpServerField.allCases { texts[f] = Self.fieldText(row, f) }
        stdio = row["transport"].string == "stdio"
        loopback = row["oauthRedirect"].string == "loopback"
        enabled = !row["enabled"].is(false)
        repos = row["repos"].strings
        clear = []
        dirty = false
    }

    /// The names of what is stored, which the empty box says.
    func cue(_ f: McpServerField) -> String {
        switch f {
        case .headers where !row["headerNames"].strings.isEmpty: return "Stored: \(row["headerNames"].strings.joined(separator: ", ")) · type to replace"
        case .env where !row["envNames"].strings.isEmpty: return "Stored: \(row["envNames"].strings.joined(separator: ", ")) · type to replace"
        case .oauthClientSecret where row["hasOAuthClientSecret"].is(true): return "Stored · type a new one to replace it"
        default: return f.def.cue ?? ""
        }
    }
    func stored(_ f: McpServerField) -> Bool {
        switch f {
        case .headers: return !row["headerNames"].strings.isEmpty
        case .env: return !row["envNames"].strings.isEmpty
        case .oauthClientSecret: return row["hasOAuthClientSecret"].is(true)
        default: return false
        }
    }

    mutating func toggle(_ repo: String) {
        if let i = repos.firstIndex(of: repo) { repos.remove(at: i) } else { repos.append(repo) }
    }

    /// `Name: value` lines (headers) or `NAME=value` lines (environment) as the server takes them; nil with what is wrong.
    static func pairs(_ text: String, env: Bool) -> Result<JSON, FormProblem> {
        var out: [String: JSON] = [:]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\r", with: "")
            if line.isEmpty { continue }
            guard let sep = line.firstIndex(of: env ? "=" : ":") else {
                return .failure(FormProblem(message: env ? "Write each variable as NAME=value." : "Write each header as Name: value."))
            }
            let name = line[..<sep].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            let ok = env ? mcpEnvName(name) : mcpHeaderName(name)
            guard ok else {
                return .failure(FormProblem(message: env ? "\(name.isEmpty ? "A variable" : name) is not a valid name: letters, digits and _, not starting with a digit."
                                                        : "\(name.isEmpty ? "A header" : name) is not a valid header name."))
            }
            guard value.utf16.count <= 8192 else { return .failure(FormProblem(message: "A value is longer than 8,192 characters.")) }
            out[name] = .string(value)
        }
        guard out.count <= 32 else { return .failure(FormProblem(message: "At most 32 \(env ? "variables" : "headers").")) }
        return .success(.object(out))
    }

    func body() -> Result<JSON, FormProblem> {
        var body: JSON = [:]
        let name = text(.name).cTrimmed
        guard mcpToolName(name) else { return .failure(FormProblem(message: "Use 1 to 64 letters, digits, _ or - for the tool name.")) }
        guard !Self.reserved.contains(name) else { return .failure(FormProblem(message: "\(name) is one of Briareus's own tool names.")) }
        body["name"] = .string(name)
        body["label"] = .string(text(.label).cTrimmed)
        body["transport"] = .string(stdio ? "stdio" : "http")
        for f in [McpServerField.oauthClientId, .oauthScope, .oauthClientName] {
            let t = text(f).cTrimmed
            if t.unicodeScalars.contains(where: { $0.value < 32 }) { return .failure(FormProblem(message: "\(f.def.label) holds a control character.")) }
            body[f.key] = .string(t)
        }
        body["oauthRedirect"] = .string(loopback ? "loopback" : "callback")
        if stdio {
            let command = text(.command).cTrimmed
            guard !command.isEmpty else { return .failure(FormProblem(message: "Enter the command that starts it on the Briareus machine.")) }
            let args = text(.args).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard args.count <= 64 else { return .failure(FormProblem(message: "At most 64 arguments.")) }
            body["command"] = .string(command); body["args"] = JSON(args); body["url"] = ""
        } else {
            let url = text(.url).cTrimmed
            guard mcpSecureURL(url) else { return .failure(FormProblem(message: "Enter an https endpoint, or http on the Briareus machine itself (localhost).")) }
            body["url"] = .string(url); body["command"] = ""; body["args"] = .array([])
        }
        body["repos"] = JSON(repos)
        body["enabled"] = .bool(enabled)
        // Write-only: left empty, what is stored stays; cleared, it goes; typed, it replaces the stored set.
        for f in [McpServerField.headers, .env] where (f == .headers) != stdio {
            if clear.contains(f) { body[f.key] = .object([:]); continue }
            let t = text(f)
            if t.cTrimmed.isEmpty { continue }
            switch Self.pairs(t, env: f == .env) {
            case .failure(let p): return .failure(p)
            case .success(let map): body[f.key] = map
            }
        }
        if clear.contains(.oauthClientSecret) { body["oauthClientSecret"] = "" }
        else if !text(.oauthClientSecret).cTrimmed.isEmpty { body["oauthClientSecret"] = .string(text(.oauthClientSecret).cTrimmed) }
        return .success(body)
    }

    var changed: Bool {
        if stdio != (row["transport"].string == "stdio") || loopback != (row["oauthRedirect"].string == "loopback") || enabled == row["enabled"].is(false) { return true }
        if !clear.isEmpty || !sameRepos(repos, row["repos"].strings) { return true }
        return McpServerField.allCases.contains { text($0) != Self.fieldText(row, $0) }
    }

    /// "Remote · ready", "Command · needs sign-in · 2 projects".
    static func sidebarLine(_ row: JSON) -> String {
        let kind = row["transport"].string == "stdio" ? "command" : "remote"
        let n = row["repos"].count
        return "\(kind) · \(mcpStatusText(row["status"].string)) · \(n == 0 ? "every project" : "\(n) project\(n == 1 ? "" : "s")")"
    }
}

func mcpStatusText(_ status: String?) -> String {
    switch status {
    case "ready": return "ready"
    case "needs-sign-in": return "needs sign-in"
    case "error": return "error"
    default: return "not checked"
    }
}
/// A tool name: 1 to 64 letters, digits, _ and -.
func mcpToolName(_ s: String) -> Bool {
    !s.isEmpty && s.count <= 64 && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
}
private func mcpEnvName(_ s: String) -> Bool {
    guard let first = s.unicodeScalars.first, s.count <= 128, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
    return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
}
private func mcpHeaderName(_ s: String) -> Bool {
    !s.isEmpty && s.count <= 128 && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_!#$%&'*+.^`|~-".unicodeScalars.contains($0)) }
}
/// An endpoint Briareus may call: https anywhere, http only on its own loopback address; no credentials or spaces in the
/// host, a port 1-65535 when given.
func mcpSecureURL(_ url: String) -> Bool {
    if url.unicodeScalars.contains(where: { $0.value < 32 }) { return false }
    let https = url.hasPrefix("https://"), http = url.hasPrefix("http://")
    guard https || http else { return false }
    let rest = url.dropFirst(https ? 8 : 7)
    let authority = rest.prefix { !"/?#".contains($0) }
    guard !authority.isEmpty, !authority.contains(where: { $0 == "@" || $0 == "\\" || $0.isWhitespace }) else { return false }
    var host = authority, port: Substring?
    if authority.hasPrefix("[") {
        guard let close = authority.firstIndex(of: "]") else { return false }
        host = authority[...close]
        let after = authority[authority.index(after: close)...]
        if !after.isEmpty { guard after.hasPrefix(":") else { return false }; port = after.dropFirst() }
    } else if let colon = authority.firstIndex(of: ":") {
        host = authority[..<colon]; port = authority[authority.index(after: colon)...]
    }
    guard !host.isEmpty else { return false }
    if let port {
        guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }), port.count <= 5, let n = Int(port), (1...65535).contains(n) else { return false }
    }
    return https || host == "localhost" || host == "127.0.0.1" || host == "[::1]"
}
/// The address a loopback sign-in ended on, as pasted: one the server can finish (a state and a code or an error).
func mcpCallbackURL(_ url: String) -> Bool {
    guard mcpSecureURL(url), let q = url.firstIndex(of: "?") else { return false }
    let query = url[url.index(after: q)...].prefix { $0 != "#" }
    let keys = Set(query.split(separator: "&").compactMap { pair -> String? in
        guard let eq = pair.firstIndex(of: "="), pair.index(after: eq) < pair.endIndex else { return nil }
        return String(pair[..<eq])
    })
    return keys.contains("state") && (keys.contains("code") || keys.contains("error"))
}
