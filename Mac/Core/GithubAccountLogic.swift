// The GitHub account form's fields and what a save sends (core #317, /settings/github/accounts): a label, a write-only
// token the server verifies with GitHub, and the projects the account serves, each served by one account at most. What
// GitHub said about the token (its login, user id and classic scopes) is read-only and shown as a summary. The token never
// comes back: its box starts empty, and a save with it empty keeps the stored one.
import Foundation

enum GithubAccountField: Int, CaseIterable, Sendable {
    case label, token
    var def: SettingsField {
        switch self {
        case .label: return SettingsField(key: "label", kind: .text, label: "Label", cue: "Acme bot",
            hint: "Leave empty to name it after the GitHub login, which follows the login when the token changes.")
        case .token: return SettingsField(key: "token", kind: .text, label: "Token", cue: "Paste a GitHub token",
            hint: "A classic or fine-grained personal access token. The server checks it with GitHub, stores it encrypted and never sends it back.",
            mono: true, secret: true)
        }
    }
    var key: String { def.key ?? "" }
    /// How much a box takes, as its edit's limit (the server's own).
    var limit: Int { self == .token ? 4096 : 200 }
}

/// One line of the read-only summary of what GitHub said about the stored token.
struct GithubAccountFact: Equatable, Sendable {
    enum Kind: Sendable { case login, githubID, scopes }
    var kind: Kind
    var label: String
    var value: String
    var mono = false
}

struct GithubAccountFormState: Equatable, Sendable {
    /// What the form was filled from: the saved row, or empty for a new account (the list has no defaults).
    var row: JSON
    var texts: [GithubAccountField: String] = [:]
    /// The projects ticked, as `owner/name`.
    var repos: [String] = []
    var dirty = false

    init(row: JSON) { self.row = row.isObject ? row : [:]; fill() }

    /// A GitHub account's registry id is the time it was added in milliseconds, as a Forge account's is.
    var id: Double { SSHServerFormState.rowID(row) }
    var hasToken: Bool { row["hasToken"].is(true) }
    func text(_ f: GithubAccountField) -> String { texts[f] ?? "" }

    static func fieldText(_ row: JSON, _ f: GithubAccountField) -> String { f == .token ? "" : row[f.key].string ?? "" }
    mutating func fill() {
        for f in GithubAccountField.allCases { texts[f] = Self.fieldText(row, f) }
        repos = row["repos"].strings
        dirty = false
    }

    /// What the token's box says while it is empty: whether one is stored.
    var tokenCue: String { hasToken ? "Stored · paste a new token to replace it" : GithubAccountField.token.def.cue ?? "" }

    mutating func toggle(_ repo: String) {
        if let i = repos.firstIndex(of: repo) { repos.remove(at: i) } else { repos.append(repo) }
    }

    func body() -> Result<JSON, FormProblem> {
        var body: JSON = [:]
        // A label sent at all stops following the login, so an update sends it only when it was changed: the server keeps
        // one left alone as it was, following the login or not. An emptied box follows the login again.
        if id == 0 || text(.label) != Self.fieldText(row, .label) { body["label"] = .string(text(.label).cTrimmed) }
        // An empty token is left out, so the stored one stays.
        let token = text(.token).cTrimmed
        if !token.isEmpty { body["token"] = .string(token) }
        body["repos"] = JSON(repos)
        if !hasToken && token.isEmpty { return .failure(FormProblem(message: "Paste a GitHub token for this account.")) }
        return .success(body)
    }

    /// Whether the form holds a change not saved yet, for the dot after the tab's title. The projects compare in any order.
    var changed: Bool {
        !sameRepos(repos, row["repos"].strings) || GithubAccountField.allCases.contains { text($0) != Self.fieldText(row, $0) }
    }

    /// The label of the other saved account that already serves `repo`, if one does: the server gives a project one
    /// account at most and matches names case-insensitively.
    func takenBy(_ repo: String, accounts: [JSON]) -> String? {
        let name = repo.lowercased()
        for a in accounts where !(id != 0 && SSHServerFormState.rowID(a) == id) {
            if a["repos"].strings.contains(where: { $0.lowercased() == name }) {
                return a["label"].nonEmpty ?? a["login"].nonEmpty.map { "@\($0)" } ?? "another account"
            }
        }
        return nil
    }

    /// What GitHub said about the stored token, for the read-only summary; empty for an account with no token yet.
    static func facts(_ row: JSON) -> [GithubAccountFact] {
        guard row["hasToken"].is(true) || row["login"].nonEmpty != nil else { return [] }
        var out: [GithubAccountFact] = []
        if let login = row["login"].nonEmpty { out.append(GithubAccountFact(kind: .login, label: "Login", value: "@\(login)")) }
        if let n = row["githubId"].number, n > 0 {
            out.append(GithubAccountFact(kind: .githubID, label: "GitHub user id", value: String(format: "%.0f", n), mono: true))
        }
        out.append(GithubAccountFact(kind: .scopes, label: "Scopes", value: scopesText(row["scopes"]), mono: !row["scopes"].strings.isEmpty))
        return out
    }

    /// The token's classic OAuth scopes. Null is a fine-grained token, which GitHub reports no scopes for: its permissions
    /// are unknown here, not missing. An empty list is a classic token granted none.
    static func scopesText(_ scopes: JSON) -> String {
        guard scopes.isArray else { return "Fine-grained token, scopes not reported" }
        let granted = scopes.strings.filter { !$0.isEmpty }
        return granted.isEmpty ? "None granted" : granted.joined(separator: ", ")
    }

    /// What a refused save says, where the server's own words would not tell the admin what to do: a project another
    /// account already serves (409). Nil leaves the server's answer as it is (400, 404, 502, the retryable 503).
    static func saveProblem(_ error: APIError) -> String? {
        guard error.kind == .http, error.status == 409 else { return nil }
        return "A ticked project is already served by another GitHub account. Untick it there first, then save this one."
    }

    /// What a saved account is called: its label, else its login.
    static func title(_ row: JSON) -> String { row["label"].nonEmpty ?? row["login"].nonEmpty.map { "@\($0)" } ?? "GitHub account" }

    /// The sidebar row's second line: the login, and its one project or how many.
    static func sidebarLine(_ row: JSON) -> String {
        let who = row["login"].nonEmpty.map { "@\($0)" } ?? "no token", repos = row["repos"].strings
        if repos.count == 1 { return "\(who) · \(repos[0])" }
        return "\(who) · \(repos.count) projects"
    }
    /// The header's subtitle for a saved account: the login, how many projects, and a missing token.
    static func subtitle(_ row: JSON) -> String {
        let n = row["repos"].count
        let who = row["login"].nonEmpty.map { "@\($0) · " } ?? ""
        return "\(who)\(n) project\(n == 1 ? "" : "s")\(row["hasToken"].is(true) ? "" : " · no token")"
    }
}
