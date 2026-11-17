// The GitHub account the server uses for one project (`GET /github/account?repo=`, any token held to the project) and an
// admin's on-demand check of it (`GET /settings/github/health?repo=`): parsing, the identity line, the health rows (token,
// scopes, each repository's access, REST and GraphQL budgets) and one overall state. Both apps' project settings draw
// these; `githubAccountPhrase(_:)` names the account wherever a refusal mentions it. No UI here.
import Foundation

/// The server's GitHub identity for one project: a registered account, or the global `GITHUB_TOKEN` fallback. It never
/// carries a token, nor a connected user's personal identity.
struct GithubAccountIdentity: Equatable, Sendable {
    /// The registry id; nil for the global fallback.
    var id: Int?
    /// The account's label; `GITHUB_TOKEN` for the global fallback.
    var label: String
    /// The GitHub login it was verified as; nil for the global fallback (until a health check reads it).
    var login: String?
    var globalFallback: Bool
    /// Whether the selected credential exists at all.
    var hasToken: Bool

    init(id: Int? = nil, label: String, login: String? = nil, globalFallback: Bool, hasToken: Bool) {
        self.id = id; self.label = label; self.login = login; self.globalFallback = globalFallback; self.hasToken = hasToken
    }

    /// From the account object, or from `{ account }` as `GET /github/account` answers.
    init?(_ raw: JSON) {
        let j = raw["account"].isObject ? raw["account"] : raw
        guard j.isObject, let fallback = j["globalFallback"].bool else { return nil }
        id = j["id"].int
        label = j["label"].nonEmpty ?? (fallback ? "GITHUB_TOKEN" : "")
        login = j["login"].nonEmpty
        globalFallback = fallback
        hasToken = j["hasToken"].bool ?? false
    }

    /// "label · @login" for an assigned account, the server's token for the fallback, or that there is no token at all.
    var line: String {
        if !hasToken { return "No GitHub token" }
        if globalFallback { return login.map { "Server GITHUB_TOKEN · @\($0)" } ?? "Server GITHUB_TOKEN" }
        return [label.isEmpty ? nil : label, login.map { "@\($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// What the line leaves out: the account a missing token belongs to, or that no account serves the project.
    var detail: String? {
        if !hasToken { return globalFallback ? "No account serves this project and the server has no GITHUB_TOKEN." : "Account \(label)" }
        return globalFallback ? "No GitHub account is assigned to this project." : nil
    }

    var tone: RowTone { !hasToken ? .danger : globalFallback ? .muted : .ok }
    var symbol: String { !hasToken ? "exclamationmark.triangle" : globalFallback ? "server.rack" : "person.crop.circle" }
}

/// How a message names the account that read GitHub for a project: the loaded identity when there is one, else the
/// project's account in general. For refusals such as "could not read the board with …".
func githubAccountPhrase(_ identity: GithubAccountIdentity?) -> String {
    guard let identity else { return "the project's GitHub account" }
    if !identity.hasToken { return "no GitHub token" }
    if identity.globalFallback { return "the server's GITHUB_TOKEN" }
    let login = identity.login.map { "@\($0)" }
    switch (identity.label.isEmpty ? nil : identity.label, login) {
    case let (label?, login?): return "the GitHub account \(label) (\(login))"
    case let (label?, nil): return "the GitHub account \(label)"
    case let (nil, login?): return "the GitHub account \(login)"
    case (nil, nil): return "the project's GitHub account"
    }
}

/// `GET /settings/github/health`: the selected account checked against GitHub, with every repository it serves.
struct GithubAccountHealth: Equatable, Sendable {
    enum TokenStatus: String, Sendable {
        case valid, invalid, missing, noAccess = "no_access", rateLimited = "rate_limited", unavailable, unknown
    }
    enum ScopeStatus: String, Sendable { case ok, missing, unknown }
    enum RepoStatus: String, Sendable {
        case ok, noAccess = "no_access", invalid, rateLimited = "rate_limited", unavailable, notChecked = "not_checked", unknown
    }

    struct Scopes: Equatable, Sendable {
        var status: ScopeStatus
        /// What the classic token reports; nil when GitHub sent no scopes header (a fine-grained token), which is not
        /// the same as granting none.
        var granted: [String]?
        var required: [String]
        /// nil when unknown; empty when every required scope is granted.
        var missing: [String]?
    }

    struct RepoAccess: Equatable, Sendable, Identifiable {
        var repo: String
        /// true or false once checked; nil when not checked or GitHub could not say.
        var accessible: Bool?
        var status: RepoStatus
        var httpStatus: Int?
        var id: String { repo }
    }

    /// One budget: nil values until a response has been observed.
    struct Bucket: Equatable, Sendable {
        var remaining: Int?
        var limit: Int?
        var resetAt: Date?
    }

    struct RateLimit: Equatable, Sendable {
        var core: Bucket?
        var graphql: Bucket?
        /// When requests may resume after a local back-off; nil when none was set (the server sends 0).
        var coreCooldown: Date?
        var graphqlCooldown: Date?
    }

    var account: GithubAccountIdentity?
    var healthy: Bool
    var token: TokenStatus
    var tokenHTTPStatus: Int?
    var scopes: Scopes
    var repos: [RepoAccess]
    /// nil when the account has no token.
    var rateLimit: RateLimit?

    init?(_ j: JSON) {
        guard j.isObject, let healthy = j["healthy"].bool, j["token"].isObject else { return nil }
        self.healthy = healthy
        account = GithubAccountIdentity(j["account"])
        token = TokenStatus(rawValue: j["token"]["status"].string ?? "") ?? .unknown
        tokenHTTPStatus = j["token"]["httpStatus"].int
        let s = j["scopes"]
        scopes = Scopes(status: ScopeStatus(rawValue: s["status"].string ?? "") ?? .unknown,
                        granted: s["granted"].array.map(Self.strings),
                        required: Self.strings(s["required"].array ?? []),
                        missing: s["missing"].array.map(Self.strings))
        repos = (j["repos"].array ?? []).compactMap { r in
            guard let repo = r["repo"].nonEmpty else { return nil }
            return RepoAccess(repo: repo, accessible: r["accessible"].bool,
                              status: RepoStatus(rawValue: r["status"].string ?? "") ?? .unknown, httpStatus: r["httpStatus"].int)
        }
        let rate = j["rateLimit"]
        rateLimit = rate.isObject
            ? RateLimit(core: Self.bucket(rate["core"]), graphql: Self.bucket(rate["graphql"]),
                        coreCooldown: Self.epoch(rate["cooldownUntil"]["core"]),
                        graphqlCooldown: Self.epoch(rate["cooldownUntil"]["graphql"]))
            : nil
    }

    private static func strings(_ a: [JSON]) -> [String] { a.compactMap(\.nonEmpty) }
    private static func bucket(_ j: JSON) -> Bucket? {
        j.isObject ? Bucket(remaining: j["remaining"].int, limit: j["limit"].int, resetAt: epoch(j["resetAt"])) : nil
    }
    /// Epoch milliseconds as a date; 0 or absent is none.
    private static func epoch(_ j: JSON) -> Date? {
        guard let ms = j.number, ms.isFinite, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Whether the token is fine-grained: valid, but GitHub reported no scopes. Its scopes are unknown, not missing.
    var scopesUnreported: Bool { token == .valid && scopes.granted == nil }
}

// MARK: - What the check shows

/// The check's verdict as one line at the top of its results.
struct GithubHealthVerdict: Equatable, Sendable {
    var title: String
    var tone: RowTone
    var symbol: String
}

/// The groups a check's rows fall in, in the order they show.
enum GithubHealthSection: String, CaseIterable, Sendable {
    case token, scopes, repos, rateLimits
    var title: String {
        switch self {
        case .token: return "Token"
        case .scopes: return "Scopes"
        case .repos: return "Repositories"
        case .rateLimits: return "Rate limits"
        }
    }
}

/// One line of a check: what it is about, what it found, and the tone and symbol both apps draw it with.
struct GithubHealthRow: Equatable, Sendable, Identifiable {
    var id: String
    var section: GithubHealthSection
    var title: String
    var value: String
    var detail: String?
    var tone: RowTone
    var symbol: String
}

/// One section of a check's rows, for a list drawn section by section.
struct GithubHealthGroup: Equatable, Sendable, Identifiable {
    var section: GithubHealthSection
    var rows: [GithubHealthRow]
    var id: String { section.rawValue }
}

extension GithubAccountHealth {
    /// The rows by section, in section order, leaving out a section with none (rate limits without a token).
    func groups(now: Date = Date()) -> [GithubHealthGroup] {
        let all = rows(now: now)
        return GithubHealthSection.allCases.compactMap { section in
            let rows = all.filter { $0.section == section }
            return rows.isEmpty ? nil : GithubHealthGroup(section: section, rows: rows)
        }
    }


    /// Healthy as the server judges it; a check GitHub could not finish (throttled, unreachable) is a warning, not a fault.
    var verdict: GithubHealthVerdict {
        if healthy { return GithubHealthVerdict(title: "Healthy", tone: .ok, symbol: "checkmark.circle") }
        if token == .rateLimited || token == .unavailable {
            return GithubHealthVerdict(title: "Could not finish the check", tone: .warn, symbol: "exclamationmark.triangle")
        }
        return GithubHealthVerdict(title: "Needs attention", tone: .danger, symbol: "xmark.octagon")
    }

    /// Every row, grouped in `GithubHealthSection` order; reset and cool-down times are read against `now`.
    func rows(now: Date = Date()) -> [GithubHealthRow] {
        [tokenRow] + scopeRows + repoRows + rateRows(now: now)
    }

    private static func http(_ status: Int?) -> String? { status.map { "HTTP \($0)" } }

    private var tokenRow: GithubHealthRow {
        let value: String, tone: RowTone, symbol: String
        switch token {
        case .valid: (value, tone, symbol) = ("Valid", .ok, "checkmark.circle")
        case .missing: (value, tone, symbol) = ("No token", .danger, "xmark.circle")
        case .invalid: (value, tone, symbol) = ("Invalid", .danger, "xmark.circle")
        case .noAccess: (value, tone, symbol) = ("No access", .danger, "lock")
        case .rateLimited: (value, tone, symbol) = ("Rate limited", .warn, "hourglass")
        case .unavailable: (value, tone, symbol) = ("GitHub did not answer", .warn, "exclamationmark.triangle")
        case .unknown: (value, tone, symbol) = ("Unknown", .muted, "questionmark.circle")
        }
        // A local cool-down carries no HTTP status; only GitHub's own answers do.
        let detail = token == .rateLimited && tokenHTTPStatus == nil ? "Local cool-down" : Self.http(tokenHTTPStatus)
        let who = account.map { $0.globalFallback ? "GITHUB_TOKEN" : $0.label }
        return GithubHealthRow(id: "token", section: .token, title: who ?? "Token",
                               value: account?.login.map { "\(value) · @\($0)" } ?? value, detail: detail, tone: tone, symbol: symbol)
    }

    private var scopeRows: [GithubHealthRow] {
        let required = scopes.required.joined(separator: ", ")
        let detail = required.isEmpty ? nil : "Required: \(required)"
        let row: GithubHealthRow
        switch scopes.status {
        case .ok:
            row = GithubHealthRow(id: "scopes", section: .scopes, title: "Scopes", value: (scopes.granted ?? []).joined(separator: ", "),
                                  detail: detail, tone: .ok, symbol: "checkmark.circle")
        case .missing:
            row = GithubHealthRow(id: "scopes", section: .scopes, title: "Missing scopes", value: (scopes.missing ?? []).joined(separator: ", "),
                                  detail: detail, tone: .danger, symbol: "xmark.circle")
        case .unknown:
            // A fine-grained token reports no scopes: its permissions are unknown, never shown as missing.
            row = GithubHealthRow(id: "scopes", section: .scopes, title: "Scopes",
                                  value: scopesUnreported ? "Fine-grained token, scopes not reported" : "Not checked",
                                  detail: detail, tone: .muted, symbol: "questionmark.circle")
        }
        return [row]
    }

    private var repoRows: [GithubHealthRow] {
        guard !repos.isEmpty else {
            return [GithubHealthRow(id: "repos", section: .repos, title: "No projects", value: "This account serves no project",
                                    tone: .muted, symbol: "folder")]
        }
        return repos.map { r in
            let value: String, tone: RowTone, symbol: String
            switch r.status {
            case .ok: (value, tone, symbol) = ("Accessible", .ok, "checkmark.circle")
            case .noAccess: (value, tone, symbol) = ("No access", .danger, "lock")
            case .invalid: (value, tone, symbol) = ("Token refused", .danger, "xmark.circle")
            case .rateLimited: (value, tone, symbol) = ("Rate limited", .warn, "hourglass")
            case .unavailable: (value, tone, symbol) = ("GitHub did not answer", .warn, "exclamationmark.triangle")
            case .notChecked: (value, tone, symbol) = ("Not checked", .muted, "minus.circle")
            case .unknown: (value, tone, symbol) = ("Unknown", .muted, "questionmark.circle")
            }
            return GithubHealthRow(id: "repo:\(r.repo)", section: .repos, title: r.repo, value: value,
                                   detail: Self.http(r.httpStatus), tone: tone, symbol: symbol)
        }
    }

    private func rateRows(now: Date) -> [GithubHealthRow] {
        guard let rateLimit else { return [] }
        return [rateRow(id: "rate:core", title: "REST", rateLimit.core, cooldown: rateLimit.coreCooldown, now: now),
                rateRow(id: "rate:graphql", title: "GraphQL", rateLimit.graphql, cooldown: rateLimit.graphqlCooldown, now: now)]
    }

    private func rateRow(id: String, title: String, _ bucket: Bucket?, cooldown: Date?, now: Date) -> GithubHealthRow {
        let cooling = cooldown.flatMap { $0 > now ? $0 : nil }
        guard let remaining = bucket?.remaining else {
            return GithubHealthRow(id: id, section: .rateLimits, title: title, value: "Not used yet",
                                   detail: cooling.map { "Paused until \(formatEventTime($0, now: now))" },
                                   tone: cooling == nil ? .muted : .warn, symbol: cooling == nil ? "minus.circle" : "hourglass")
        }
        let limit = bucket?.limit
        let value = limit.map { "\(remaining) of \($0) left" } ?? "\(remaining) left"
        var notes: [String] = []
        if let cooling { notes.append("Paused until \(formatEventTime(cooling, now: now))") }
        if let reset = bucket?.resetAt, reset > now { notes.append("Resets \(formatEventTime(reset, now: now))") }
        let low = limit.map { $0 > 0 && remaining * 10 < $0 } ?? false
        let tone: RowTone = remaining == 0 || cooling != nil ? .danger : low ? .warn : .ok
        return GithubHealthRow(id: id, section: .rateLimits, title: title, value: value,
                               detail: notes.isEmpty ? nil : notes.joined(separator: " · "), tone: tone,
                               symbol: tone == .ok ? "speedometer" : "hourglass")
    }
}
