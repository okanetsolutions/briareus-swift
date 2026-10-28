// The settings forms' fields and what a save sends, as the Windows client's screen_settings.c, screen_provider_settings.c
// and screen_db_servers.c build them: each form keeps the row it was filled from and the text of every box, and the body
// is that row with every field as it stands now.
import Foundation

// MARK: - Shared

/// `board`: the Projects board, edited as its address on GitHub and saved as the setting that names it.
enum SettingsFieldKind: Sendable { case text, list, area, number, bool, board }

/// One of a form's fields: the key it edits (nil for one that is not part of the row), how, and the words around it.
/// `rows` sizes a multi-line box.
struct SettingsField: Sendable {
    let key: String?
    let kind: SettingsFieldKind
    let label: String
    var cue: String? = nil
    var hint: String? = nil
    var rows: Int = 0
    var mono = false
    var secret = false
    var isMultiline: Bool { kind == .list || kind == .area }
    var isEdit: Bool { kind != .bool }
}

/// Why a form cannot be sent as it stands, and the tab holding the field at fault.
struct FormProblem: Error, Equatable, Sendable {
    var message: String
    var tab: Int = 0
}

enum SettingsText {
    /// A list one item per line.
    static func listText(_ v: JSON) -> String { v.items.compactMap(\.string).joined(separator: "\n") }
    /// One item per line, trimmed, blank lines dropped, as the Windows client reads its textareas.
    static func list(from text: String) -> [String] {
        text.components(separatedBy: "\n").map(\.cTrimmed).filter { !$0.isEmpty }
    }
    /// A number as typed (`%.10g`), empty for anything else.
    static func numberText(_ v: JSON) -> String {
        guard let n = v.number, n.isFinite else { return "" }
        return String(format: "%.10g", n)
    }
    static func lineCount(_ text: String) -> Int { text.unicodeScalars.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
    /// Whether the row has this key. An empty row (nothing read yet) has every key; a server that dropped a setting, or
    /// predates one, gets neither the box nor the key.
    static func rowHas(_ row: JSON, _ key: String) -> Bool { row.count == 0 || row.object?[key] != nil }
    /// A whole port from 1 to 65535, as `strtol` reads one with nothing after it.
    static func port(_ text: String) -> Int? {
        guard let n = Int(text), (1...65535).contains(n) else { return nil }
        return n
    }
}

/// Why `what` cannot be managed with this token, or nil when it can: the route is there but needs an Admin token, or the
/// server does not have it.
func settingsUnavailableText(supported: Bool, listed: Bool, permission: String?, what: String, path: String, manage: String) -> String? {
    if supported { return nil }
    return listed
        ? "\(what) need an Admin token, and this device's token is \(permission ?? "unknown"). Issue an Admin token on the server with npm run create-token and connect with it."
        : "This server does not offer \(what) (GET /\(path)) on its client API. Update the server to manage \(manage) here."
}

// MARK: - Projects

enum ProjectTab: Int, CaseIterable, Sendable {
    case project, database, review, orchestrator, env, run
    var title: String {
        switch self {
        case .project: return "Project"
        case .database: return "Database"
        case .review: return "Code review"
        case .orchestrator: return "Orchestrator"
        case .env: return "Checkout .env"
        case .run: return "Run"
        }
    }
}

enum ProjectField: Int, CaseIterable, Sendable {
    case repo, label, enabled, localDir, board
    case setup, php, printing
    case dbName, dbExt, dbPool, dbRestore
    case reviewAuthor, publish, autoLoop, babysit, testSheet, testRun, qaNotes, sheetSteps, feedbackSteps
    case budget, isSelf
    case env
    case run, profiles

    var def: SettingsField {
        switch self {
        case .repo: return SettingsField(key: "repo", kind: .text, label: "Repository", cue: "owner/name", hint: "Cloned over HTTPS with the machine's own git credentials.")
        case .label: return SettingsField(key: "label", kind: .text, label: "Label", cue: "shown in the project dropdown")
        case .enabled: return SettingsField(key: "enabled", kind: .bool, label: "Active: sessions can be started on this project")
        case .localDir: return SettingsField(key: "localDir", kind: .text, label: "Local checkout", cue: "/home/you/www/your-checkout",
            hint: "This machine's own checkout of the repo. A session started in Local mode works directly in it: no clone, no setup steps, no pooled database, and the tree is used exactly as it stands. Leave empty to keep Local mode off for this project.", mono: true)
        case .board: return SettingsField(key: "projectBoard", kind: .board, label: "GitHub Projects board", cue: "https://github.com/orgs/acme/projects/1/views/2",
            hint: "The board the project's ▦ Board tab shows: its address on GitHub, with the view whose filter and columns it follows. The server's GitHub token needs Projects: read. Leave empty for no Board tab.", mono: true)
        case .printing: return SettingsField(key: "printToolsEnabled", kind: .bool, label: "Allow sessions to print on the server’s printers", hint: "Gives interactive sessions access to the server’s CUPS printers; off by default.")
        case .setup: return SettingsField(key: "setupCommands", kind: .list, label: "Setup commands",
            hint: "One shell command per line, run in the checkout in order before the session starts. The first failure aborts the session.", rows: 6, mono: true)
        case .php: return SettingsField(key: "phpBinDir", kind: .text, label: "PHP bin directory", cue: "/usr/bin (or ~/.phpenv/versions/8.4/bin)",
            hint: "Prepended to PATH for everything this project runs. Leave empty for the machine's PHP.", mono: true)
        case .dbName: return SettingsField(key: "dbPoolDatabase", kind: .text, label: "Database", cue: "my_app",
            hint: "What DB_DATABASE is set to in the session's environment. With the pool on, created on the claimed server if it does not exist yet. With the pool off, every session gets a database of its own, this name plus the session id, created on the server the .env template points at, and written into the checkout's .env. Leave empty to use the .env template as-is. Migrations and seeding belong in the setup commands.", mono: true)
        case .dbExt: return SettingsField(key: "dbExtensions", kind: .list, label: "Postgres extensions",
            hint: "One extension name per line, created in the session's database right after it is created. A fresh Postgres database carries only what template1 does, so migrations that declare a vector column fail without this. The extension itself must already be installed on the server. Ignored on MySQL.", rows: 2, mono: true)
        case .dbPool: return SettingsField(key: "dbPoolEnabled", kind: .bool, label: "Give each session a database server of its own")
        case .dbRestore: return SettingsField(key: "dbRestoreSql", kind: .text, label: "Restore from .sql", cue: "/home/you/dumps/my_app.sql",
            hint: "A dump on this machine, piped into the database every time a server is claimed, right after it is created, before the setup steps run. Leave empty to skip. The servers themselves are added under Database pool in the sidebar.", mono: true)
        case .reviewAuthor: return SettingsField(key: "reviewAuthor", kind: .text, label: "PR author", cue: "github-username", mono: true)
        case .publish: return SettingsField(key: "reviewPublishInstructions", kind: .area, label: "Publish steps",
            hint: "Sent to the agent as its own turn after a ⌕ Code review: this text and nothing else. Leave empty to run no turn after the review.", rows: 4)
        case .autoLoop: return SettingsField(key: "autonomousReviewLoop", kind: .bool, label: "Autonomous review loop: fix verified worthwhile findings")
        case .babysit: return SettingsField(key: "babysitPrs", kind: .bool, label: "Babysit pull requests: start the errand each open one needs")
        case .testSheet: return SettingsField(key: "reviewTestSheet", kind: .bool, label: "Write a test sheet when the 🎬 QA errand is started")
        case .testRun: return SettingsField(key: "reviewTestRun", kind: .bool, label: "Execute the test sheet and record a video of each scenario")
        case .qaNotes: return SettingsField(key: "qaNotes", kind: .area, label: "QA notes",
            hint: "Appended to the test sheet and test run prompts: logins, tenants, URLs, whatever a tester needs that the repository does not say.", rows: 4)
        case .sheetSteps: return SettingsField(key: "testSheetInstructions", kind: .area, label: "Test sheet closing steps",
            hint: "Appended to the end of the 📋 Test sheet prompt: what this project wants done once the sheet is on the pull request. Leave empty to add nothing.", rows: 4)
        case .feedbackSteps: return SettingsField(key: "feedbackInstructions", kind: .area, label: "Feedback closing steps",
            hint: "Appended to the end of the ⚙ Implement feedback prompt: what this project wants done once the review comments are implemented. Leave empty to add nothing.", rows: 4)
        case .budget: return SettingsField(key: "workerBudgetUsd", kind: .number, label: "Budget (USD)", cue: "no cap",
            hint: "What one orchestration may spend — the supervisor's turns plus every worker's — before it pauses and waits for you. Only turns whose provider reports a cost count. Leave empty for no cap.")
        case .isSelf: return SettingsField(key: "isSelf", kind: .bool, label: "This project is Briareus itself")
        case .env: return SettingsField(key: "envTemplate", kind: .area, label: ".env template",
            hint: "Written into the checkout as .env before the setup steps run, on every session. Leave empty to use whatever the repository ships.", rows: 10, mono: true)
        case .run: return SettingsField(key: "runCommands", kind: .list, label: "Run commands",
            hint: "What ▶ Run executes, in the checkout, one shell command per line, chained, so the last one is the server that keeps running. {port} is the session's app port, {dir} the checkout.", rows: 4, mono: true)
        case .profiles: return SettingsField(key: "runProfiles", kind: .area, label: "Run profiles",
            hint: "Optional named configurations ▶ Run can serve instead, the first being the default. env: is set over the session's environment (a DB_DATABASE of its own is created on the session's server), before: runs ahead of the run commands, and each of the tenants: gets a hostname of its own on the session's port. Extra placeholders: {profile}, {database}, {host} and {host:<tenant>}.", rows: 8, mono: true)
        }
    }
    var key: String { def.key ?? "" }
    /// What a switch's note under it says, on or off; nil for no note. Both apps draw it beneath the switch.
    func note(on: Bool) -> String? {
        switch self {
        case .enabled where !on:
            return "Inactive: no session can be started on it and it is left out of the project lists; its settings are kept for when it is switched back on."
        case .autoLoop where on:
            return "Independently verified worthwhile findings in a session’s review-loop round are fixed and reviewed again; optional findings do not prolong the loop, and findings without an assessment wait for manual triage. The loop's round limit and repeated-findings check still stop one that cannot converge. Sessions still need their review loop switched on; a standalone ⌕ Code review keeps its manual findings."
        case .babysit where on:
            return "Every 15 minutes the server starts, once per head commit, the first errand each open non-draft pull request needs: 🔀 Solve conflicts, else 🧪 Fix failing checks, else a ⌕ Code review when the board recommends one. It runs on the code review's runtime and skips pull requests labelled blocked or do-not-merge and those with a session open. With a PR author set, conflicts and checks are fixed only on that author’s pull requests, and new developer feedback is assessed for manual Findings decisions before fixes start."
        case .isSelf:
            return "Tick it on the repository whose code is running right now, and on no other. An orchestrator on any project that finds a flaw in the tooling running it (a briefing, a worker tool, a loop) can then send a fix worker here, review loop armed, and merge its pull request once the loop approves and the checks are green. The running server keeps its code until you redeploy."
        default:
            return nil
        }
    }
    /// The project and how a checkout of it is set up share the first tab.
    var tab: ProjectTab {
        switch self {
        case .repo, .label, .enabled, .localDir, .board, .setup, .php, .printing: return .project
        case .dbName, .dbExt, .dbPool, .dbRestore: return .database
        case .reviewAuthor, .publish, .autoLoop, .babysit, .testSheet, .testRun, .qaNotes, .sheetSteps, .feedbackSteps: return .review
        case .budget, .isSelf: return .orchestrator
        case .env: return .env
        case .run, .profiles: return .run
        }
    }
}

/// The provider, model and effort pickers: the code review's, each errand step's, and the orchestrator's workers'. A flat
/// one edits three keys of the project; a step edits its entry in `stepRuntimes`.
enum ProjectRuntime: Int, CaseIterable, Sendable {
    case review, testSheet, testRun, worker
    var providerKey: String? { self == .review ? "reviewProviderId" : self == .worker ? "workerProviderId" : nil }
    var modelKey: String? { self == .review ? "reviewModel" : self == .worker ? "workerModel" : nil }
    var effortKey: String? { self == .review ? "reviewEffort" : self == .worker ? "workerEffort" : nil }
    var step: String? { self == .testSheet ? "testSheet" : self == .testRun ? "testRun" : nil }
    /// What the provider picker says with no provider picked.
    var none: String {
        switch self {
        case .review: return "Pick a provider"
        case .testSheet, .testRun: return "Same as the code review"
        case .worker: return "Same as the orchestrator"
        }
    }
    var providerLabel: String { self == .worker ? "Worker provider" : "Provider" }
    var tab: ProjectTab { self == .worker ? .orchestrator : .review }
    /// The key whose presence says the server's projects carry this picker.
    var presenceKey: String { step != nil ? "stepRuntimes" : providerKey! }
}

/// A picker's runtime; provider 0 is the picker's `none`.
struct RuntimePick: Equatable, Sendable {
    var providerId = 0
    var model: String?
    var effort: String?

    func differs(from other: RuntimePick) -> Bool {
        providerId != other.providerId
            || (providerId != 0 && ((model ?? "") != (other.model ?? "") || (effort ?? "") != (other.effort ?? "")))
    }
}

struct ProjectFormState: Equatable, Sendable {
    /// What the form was filled from: the saved row, the defaults, or a clone's values.
    var row: JSON
    var texts: [ProjectField: String] = [:]
    var bools: [ProjectField: Bool] = [:]
    var picks: [ProjectRuntime: RuntimePick] = [:]
    var dirty = false

    init(row: JSON) { self.row = row.isObject ? row : [:]; fill() }

    /// 0 until the project is saved.
    var id: Int { row["id"].int32 ?? 0 }

    /// Fills every field from the row; nothing is unsaved afterwards.
    mutating func fill() {
        for f in ProjectField.allCases {
            if f.def.isEdit { texts[f] = Self.fieldText(row, f) } else { bools[f] = row[f.key].is(true) }
        }
        for r in ProjectRuntime.allCases { picks[r] = savedPick(r) }
        dirty = false
    }

    func has(_ key: String) -> Bool { SettingsText.rowHas(row, key) }
    func offered(_ f: ProjectField) -> Bool { has(f.key) }
    func offered(_ r: ProjectRuntime) -> Bool { has(r.presenceKey) }
    /// The restore dump only means something with the pool on.
    func enabled(_ f: ProjectField) -> Bool { f != .dbRestore || bools[.dbPool] == true }
    func text(_ f: ProjectField) -> String { texts[f] ?? "" }
    func bool(_ f: ProjectField) -> Bool { bools[f] ?? false }
    func pick(_ r: ProjectRuntime) -> RuntimePick { picks[r] ?? RuntimePick() }

    /// A field's value in the row as its box shows it: a list one item per line, a number as typed, empty for null.
    static func fieldText(_ row: JSON, _ f: ProjectField) -> String {
        let v = row[f.key]
        switch f.def.kind {
        case .list: return SettingsText.listText(v)
        case .number: return SettingsText.numberText(v)
        case .board: return projectBoardSettingURL(v) ?? ""
        default: return v.string ?? ""
        }
    }
    /// A picker's runtime as the row has it saved.
    func savedPick(_ r: ProjectRuntime) -> RuntimePick {
        if let step = r.step {
            let src = row["stepRuntimes"][step]
            return RuntimePick(providerId: src["providerId"].int32 ?? 0, model: src["model"].string, effort: src["effort"].string)
        }
        return RuntimePick(providerId: row[r.providerKey!].int32 ?? 0, model: row[r.modelKey!].string, effort: row[r.effortKey!].string)
    }

    /// Whether a tab holds a change not saved yet, for the dot after its title.
    func tabChanged(_ t: ProjectTab) -> Bool {
        for f in ProjectField.allCases where f.tab == t && offered(f) {
            if !f.def.isEdit { if bool(f) != row[f.key].is(true) { return true }; continue }
            if text(f) != Self.fieldText(row, f) { return true }
        }
        for r in ProjectRuntime.allCases where r.tab == t {
            if pick(r).differs(from: savedPick(r)) { return true }
        }
        return false
    }

    /// The body a save sends: the row the form came from with every field as it stands now.
    func body() -> Result<JSON, FormProblem> {
        var body: JSON = row.isObject ? row : [:]
        // What the server sets itself, and the order, which belongs to the list's Move up and Move down.
        for k in ["id", "createdAt", "updatedAt", "sortOrder"] { body.remove(k) }
        for f in ProjectField.allCases where offered(f) {
            let key = f.key
            switch f.def.kind {
            case .bool: body[key] = .bool(bool(f))
            case .text: body[key] = .string(text(f).cTrimmed)
            case .area: body[key] = .string(text(f))
            case .list: body[key] = JSON(SettingsText.list(from: text(f)))
            case .board:
                let t = text(f).cTrimmed
                guard let board = t.isEmpty ? JSON.null : projectBoardSetting(fromURL: t) else {
                    return .failure(FormProblem(message: "\(f.def.label) must be the board's address on GitHub, such as https://github.com/orgs/acme/projects/1/views/2, or empty for none.", tab: f.tab.rawValue))
                }
                body[key] = board
            case .number:
                let t = text(f).cTrimmed
                if t.isEmpty { body[key] = .null }
                else if let n = Double(t), n.isFinite, n >= 0 { body[key] = .number(n) }
                else {
                    return .failure(FormProblem(message: "\(f.def.label) must be a number of dollars, such as 25 or 12.5, or empty for no cap.", tab: f.tab.rawValue))
                }
            }
        }
        let repo = (body["repo"].string ?? "").cTrimmed
        if repo.isEmpty || !repo.contains("/") || repo.hasPrefix("/") || repo.hasSuffix("/") {
            return .failure(FormProblem(message: "Enter the repository as owner/name.", tab: ProjectTab.project.rawValue))
        }
        // The runtimes. A step left on "Same as the code review" is no entry at all rather than empty strings.
        let hasSteps = has("stepRuntimes")
        var steps: JSON = body["stepRuntimes"].isObject ? body["stepRuntimes"] : [:]
        for r in ProjectRuntime.allCases where has(r.presenceKey) {
            let p = pick(r)
            if let step = r.step {
                if p.providerId == 0 { steps.remove(step); continue }
                steps[step] = ["providerId": JSON(p.providerId), "model": .string(p.model ?? ""), "effort": .string(p.effort ?? "")]
                continue
            }
            body[r.providerKey!] = p.providerId != 0 ? JSON(p.providerId) : .null
            body[r.modelKey!] = .string(p.providerId != 0 ? p.model ?? "" : "")
            body[r.effortKey!] = .string(p.providerId != 0 ? p.effort ?? "" : "")
        }
        if hasSteps { body["stepRuntimes"] = steps }
        return .success(body)
    }

    /// What a picker shows: the provider (with "(unavailable)" for one the catalog no longer has), the model, the effort.
    func pickText(_ r: ProjectRuntime, part: Int, catalog: RuntimeCatalog?) -> String {
        let p = pick(r)
        if part == 0 {
            if p.providerId == 0 { return r.none }
            if let pr = catalog?.provider(p.providerId) { return pr.label }
            return "Provider #\(p.providerId)\(catalog != nil ? " (unavailable)" : "")"
        }
        if p.providerId == 0 { return "—" }
        if part == 1 {
            let choice = RuntimeChoice(providerId: p.providerId, model: p.model, effort: p.effort)
            if let m = catalog?.model(for: choice) { return m.title }
            return (p.model ?? "").isEmpty ? "—" : p.model!
        }
        return (p.effort ?? "").isEmpty ? "—" : p.effort!
    }
}

// MARK: - Providers

enum ProviderTab: Int, CaseIterable, Sendable {
    case provider, models, status
    var title: String { self == .provider ? "Provider" : self == .models ? "Models" : "Status" }
}

enum ProviderField: Int, CaseIterable, Sendable {
    case label, baseUrl, apiKey, models, efforts, defaultModel, defaultEffort, loginCode
    var def: SettingsField {
        switch self {
        case .label: return SettingsField(key: "label", kind: .text, label: "Label", cue: "shown in the provider picker")
        case .baseUrl: return SettingsField(key: "baseUrl", kind: .text, label: "Base URL", cue: "empty = the binary's own service", mono: true)
        case .apiKey: return SettingsField(key: "apiKey", kind: .text, label: "API token", mono: true, secret: true)
        case .models: return SettingsField(key: "models", kind: .list, label: "Models", rows: 4, mono: true)
        case .efforts: return SettingsField(key: "efforts", kind: .list, label: "Efforts", rows: 4, mono: true)
        case .defaultModel: return SettingsField(key: "defaultModel", kind: .text, label: "Default model", cue: "empty = the CLI's default", mono: true)
        case .defaultEffort: return SettingsField(key: "defaultEffort", kind: .text, label: "Default effort", cue: "empty = the CLI's default", mono: true)
        case .loginCode: return SettingsField(key: nil, kind: .text, label: "Code from the browser", cue: "paste the code from the browser", mono: true)
        }
    }
    var tab: ProviderTab {
        switch self {
        case .label, .baseUrl, .apiKey, .loginCode: return .provider
        default: return .models
        }
    }
}

struct ProviderFormState: Equatable, Sendable {
    /// The CLIs a provider runs, as the Windows client's Binary select offers them.
    static let binaries: [(id: String, title: String)] = [
        ("claude", "claude (Claude Code)"), ("codex", "codex (Codex)"), ("grok", "grok (Grok)"), ("opencode", "opencode"),
    ]
    static func == (a: ProviderFormState, b: ProviderFormState) -> Bool {
        a.row == b.row && a.texts == b.texts && a.active == b.active && a.token == b.token && a.binary == b.binary && a.dirty == b.dirty
    }

    var row: JSON
    var texts: [ProviderField: String] = [:]
    var active = true
    /// The Mode: an API token rather than the CLI's own login. Not stored: a row with a token or an endpoint is in this mode.
    var token = false
    var binary = "claude"
    var dirty = false

    init(row: JSON) { self.row = row.isObject ? row : [:]; fill() }

    var id: Int { row["id"].int32 ?? 0 }
    static func rowBinary(_ row: JSON) -> String { row["binary"].nonEmpty ?? "claude" }

    mutating func fill() {
        active = !row["active"].is(false)
        binary = Self.rowBinary(row)
        token = row["apiKey"].nonEmpty != nil || row["baseUrl"].nonEmpty != nil
        for f in ProviderField.allCases where f.def.key != nil { texts[f] = Self.fieldText(row, f) }
        dirty = false
    }

    func text(_ f: ProviderField) -> String { texts[f] ?? "" }

    /// grok has no token mode and opencode nothing but a key, so only claude and codex choose.
    static func modeOffered(_ binary: String) -> Bool { binary != "grok" && binary != "opencode" }
    /// Whether the endpoint and its token are part of the provider: the API token mode, or opencode's key.
    var usesToken: Bool { binary == "opencode" || (binary != "grok" && token) }
    /// A login is registered against a saved row, so only a saved one logged in through its CLI can log in.
    var canLogIn: Bool { id != 0 && !usesToken && binary != "opencode" }

    static func binaryTitle(_ binary: String) -> String {
        binaries.first { $0.id == binary }?.title ?? (binary.isEmpty ? "Pick a binary" : binary)
    }
    static func baseURLHint(_ binary: String) -> String {
        if binary == "claude" { return "Passed to the claude CLI as `ANTHROPIC_BASE_URL`, for a proxy or an Anthropic-compatible endpoint. Leave empty for the Anthropic API." }
        if binary == "opencode" { return "The base URL of the service this entry's models name (`anthropic` for `anthropic/claude-sonnet-4-5`), for a proxy or a compatible gateway; include the `/v1` when the service's own URL carries one. Handed to the CLI as an inline config (`OPENCODE_CONFIG_CONTENT`) alongside the key, so the machine's own opencode config is never touched. Leave empty for the service's own endpoint." }
        return "A custom API endpoint driven through the codex CLI (Responses wire format). Sessions run with a server-written `CODEX_HOME` pointing codex at it, so the machine's own `~/.codex` login is never touched. Leave empty for the binary's own service."
    }
    static func apiKeyHint(_ binary: String) -> String {
        if binary == "claude" { return "Passed as `ANTHROPIC_API_KEY`, used instead of a login. With a base URL it also goes out as `ANTHROPIC_AUTH_TOKEN`, so gateways that read `Authorization` instead of `x-api-key` see it too." }
        if binary == "opencode" { return "The key for the service this entry's models name: `anthropic` for `anthropic/claude-sonnet-4-5`. It is handed to the CLI as its whole credential store, so the machine's own opencode credentials stay untouched." }
        return "Authenticates the base URL above."
    }

    /// A field's value in the row, as the box shows it: a list one item per line.
    static func fieldText(_ row: JSON, _ f: ProviderField) -> String {
        guard let key = f.def.key else { return "" }
        return f.def.kind == .list ? SettingsText.listText(row[key]) : row[key].string ?? ""
    }
    /// A field's value as the form would send it: trimmed, and the endpoint's emptied when the mode drops it.
    func fieldNow(_ f: ProviderField) -> String {
        if (f == .baseUrl || f == .apiKey) && !usesToken { return "" }
        if f.def.kind == .list { return SettingsText.list(from: text(f)).joined(separator: "\n") }
        return text(f).cTrimmed
    }

    /// The body a save sends; `validate` false takes the form as it stands (a clone).
    func body(validate: Bool = true) -> Result<JSON, FormProblem> {
        var body: JSON = row.isObject ? row : [:]
        // What the server sets itself; the login never leaves it, and the order belongs to the list.
        for k in ["id", "createdAt", "updatedAt", "sortOrder", "hasLogin", "loginDir"] { body.remove(k) }
        body["binary"] = .string(binary)
        body["active"] = .bool(active)
        for f in ProviderField.allCases {
            guard let key = f.def.key else { continue }
            let v = fieldNow(f)
            body[key] = f.def.kind == .list ? JSON(SettingsText.list(from: v)) : .string(v)
        }
        if validate && (body["label"].string ?? "").isEmpty {
            return .failure(FormProblem(message: "Enter a label: it is what the provider picker shows.", tab: ProviderTab.provider.rawValue))
        }
        return .success(body)
    }

    func tabChanged(_ t: ProviderTab) -> Bool {
        if t == .provider && (active != !row["active"].is(false) || binary != Self.rowBinary(row)) { return true }
        for f in ProviderField.allCases where f.tab == t && f.def.key != nil {
            if fieldNow(f) != Self.fieldText(row, f) { return true }
        }
        return false
    }
}

/// What a provider's status says.
enum ProviderStatusText {
    /// The connection at a glance: a sentence and its dot's status. Nil before a status was read.
    static func headline(_ status: JSON) -> (text: String, dot: String)? {
        guard status.isObject else { return nil }
        let auth = status["auth"], logged = auth["loggedIn"]
        let available = !status["available"].is(false)
        let email = auth["email"].nonEmpty, detail = auth["detail"].nonEmpty
        let dot = !available || logged.is(false) ? "failed" : logged.is(true) ? "idle" : ""
        if !available { return ("The CLI is not installed on this machine", dot) }
        if logged.is(true) { return (email.map { "Connected: \($0)" } ?? "Connected", dot) }
        if logged.is(false) { return (detail.map { "Not connected: \($0)" } ?? "Not connected", dot) }
        return ("Connection not checked yet", dot)
    }
    /// A device login started when the status's `auth` was `from` has landed: the status says logged in, and either it
    /// did not then or the login it names changed. An entry logged in already reads as logged in before the new one lands.
    static func loginLanded(from: JSON, status: JSON) -> Bool {
        guard status["auth"]["loggedIn"].is(true) else { return false }
        guard from["loggedIn"].is(true) else { return true }
        var was = from, now = status["auth"]
        // When it was read says nothing about whose login it is.
        was.remove("checkedAt"); now.remove("checkedAt")
        return was != now
    }
    /// When a time falls: the clock today, the weekday and the clock on another day, as the Windows client prints resets.
    static func when(_ iso: String?, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        guard let date = boardDateParse(iso) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = cal.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }
    /// The status rows: label and value, the empty ones left out.
    static func rows(_ status: JSON, now: Date = Date()) -> [(label: String, value: String, mono: Bool)] {
        let auth = status["auth"]
        let email = auth["email"].nonEmpty, name = auth["name"].nonEmpty
        let account = email != nil && name != nil ? "\(email!) (\(name!))" : email ?? name ?? ""
        let plan = auth["plan"].nonEmpty?.asciiCapitalized ?? ""
        let available = !status["available"].is(false)
        var out: [(String, String, Bool)] = [
            ("Account", account, false), ("Organization", auth["organization"].string ?? "", false), ("Plan", plan, false),
        ]
        if !auth["loggedIn"].isNull { out.append(("Auth", auth["detail"].string ?? "", false)) }
        out.append(("Binary", available ? status["binSource"].string ?? "" : "not found", false))
        out.append(("Login dir", status["loginDir"].string ?? "", true))
        out.append(("Checked", when(auth["checkedAt"].string, now: now) ?? "", false))
        return out.filter { !$0.1.isEmpty }.map { (label: $0.0, value: $0.1, mono: $0.2) }
    }
    /// A quota window's label and what is said on its right.
    static func window(_ win: JSON, now: Date = Date()) -> (label: String, right: String, pct: Double) {
        let pct = win["usedPct"].number ?? 0
        let used = String(format: "%.0f%% used", pct)
        let right = when(win["resetsAt"].string, now: now).map { "\(used) · resets \($0)" } ?? used
        return (win["label"].string ?? "", right, pct)
    }
    /// What Test said when the endpoint answered, and the model list to put in the Models box (nil to leave it).
    static func testResult(_ answer: JSON, modelsNow: String) -> (text: String, models: String?) {
        if let probed = answer["probedModel"].nonEmpty {
            return ("OK: no model list route, but a chat call as \(probed) answered", nil)
        }
        let models = answer["models"].strings
        let joined = models.joined(separator: "\n")
        let same = modelsNow == joined
        let n = models.count
        return ("OK: the endpoint offers \(n) model\(n == 1 ? "" : "s")\(same ? "; the Models tab already matches" : "; they are in the Models tab, save to keep them")",
                same ? nil : joined)
    }
}

/// The providers' accounts and quota at a glance, as `GET /providers` lists them: every provider sessions start on, each
/// account with whom it is logged in as and the quota windows its plan meters. The Usage screens draw it on both apps.
enum ProviderQuota {
    /// How a provider stands: its CLI not installed, an account logged out, or ready.
    enum Health: Equatable, Sendable { case missing, loggedOut, ready }
    /// How full a quota window is: close past 70%, spent past 90%.
    enum Level: Equatable, Sendable { case ok, close, spent }

    static func providers(_ payload: JSON) -> [JSON] { payload["providers"].items }
    static func title(_ provider: JSON) -> String { provider["label"].nonEmpty ?? provider["id"].string ?? "Provider" }
    static func health(_ provider: JSON) -> Health {
        if !provider["available"].is(true) { return .missing }
        return provider["auth"]["loggedIn"].is(false) ? .loggedOut : .ready
    }
    /// The provider's logins; a server that lists no accounts gives the provider's own login and quota as the one.
    static func accounts(_ provider: JSON) -> [JSON] {
        let list = provider["accounts"].items
        return list.isEmpty && (provider["auth"].isObject || provider["usage"].isObject) ? [provider] : list
    }
    /// An account's name, said only when the provider has several logins.
    static func accountName(_ account: JSON, of provider: JSON) -> String? {
        accounts(provider).count > 1 ? account["label"].nonEmpty ?? account["id"].nonEmpty : nil
    }
    /// What is said of an account's login, and whether it is logged out.
    static func login(_ account: JSON) -> (text: String, loggedOut: Bool) {
        let auth = account["auth"]
        if auth["loggedIn"].is(false) { return ("not logged in", true) }
        return (auth["detail"].nonEmpty ?? (auth["loggedIn"].is(true) ? "logged in" : ""), false)
    }
    /// The account's quota windows, each with its label and what is said on its right.
    static func windows(_ account: JSON, now: Date = Date()) -> [(label: String, right: String, pct: Double)] {
        account["usage"]["windows"].items.map { ProviderStatusText.window($0, now: now) }
    }
    /// Why an account shows no windows, when the server says.
    static func windowsNote(_ account: JSON) -> String? {
        account["usage"]["windows"].items.isEmpty ? account["usage"]["error"].nonEmpty : nil
    }
    static func level(_ pct: Double) -> Level { pct >= 90 ? .spent : pct >= 70 ? .close : .ok }
}

// MARK: - Database servers

enum DBServerTab: Int, CaseIterable, Sendable {
    case server, pool
    var title: String { self == .server ? "Server" : "Pool" }
}

enum DBServerField: Int, CaseIterable, Sendable {
    case label, host, port, username, password
    var def: SettingsField {
        switch self {
        case .label: return SettingsField(key: "label", kind: .text, label: "Label", cue: "defaults to host:port")
        case .host: return SettingsField(key: "host", kind: .text, label: "Host", cue: "127.0.0.1", mono: true)
        case .port: return SettingsField(key: "port", kind: .number, label: "Port", cue: "3306", mono: true)
        case .username: return SettingsField(key: "username", kind: .text, label: "Username", cue: "root", mono: true)
        case .password: return SettingsField(key: "password", kind: .text, label: "Password", cue: "empty = no password", mono: true, secret: true)
        }
    }
    var key: String { def.key ?? "" }
}

struct DBServerFormState: Equatable, Sendable {
    var row: JSON
    var texts: [DBServerField: String] = [:]
    /// In the pool.
    var enabled = false
    var dirty = false

    init(row: JSON) { self.row = row.isObject ? row : [:]; fill() }

    var id: Int { row["id"].int32 ?? 0 }
    func has(_ key: String) -> Bool { SettingsText.rowHas(row, key) }
    func text(_ f: DBServerField) -> String { texts[f] ?? "" }

    mutating func fill() {
        enabled = row["enabled"].is(true)
        for f in DBServerField.allCases { texts[f] = Self.fieldText(row, f) }
        dirty = false
    }
    /// A field's value in the row as its box shows it: a port as digits, empty for null.
    static func fieldText(_ row: JSON, _ f: DBServerField) -> String {
        let v = row[f.key]
        if f.def.kind == .number {
            guard let n = v.number, n > 0 else { return "" }
            return String(format: "%.0f", n)
        }
        return v.string ?? ""
    }

    /// The body a save or a test sends.
    func body() -> Result<JSON, FormProblem> {
        var body: JSON = row.isObject ? row : [:]
        for k in ["id", "createdAt", "updatedAt", "sortOrder", "claimedBy"] { body.remove(k) }
        if has("enabled") { body["enabled"] = .bool(enabled) }
        for f in DBServerField.allCases where has(f.key) {
            // A password is sent as typed; spaces may belong to it.
            let t = f.def.secret ? text(f) : text(f).cTrimmed
            if f.def.kind != .number { body[f.key] = .string(t); continue }
            if t.isEmpty { body[f.key] = .null; continue }
            guard let port = SettingsText.port(t) else {
                return .failure(FormProblem(message: "The port must be a whole number from 1 to 65535.", tab: DBServerTab.server.rawValue))
            }
            body[f.key] = JSON(port)
        }
        return .success(body)
    }

    func tabChanged(_ t: DBServerTab) -> Bool {
        guard t == .server else { return false }
        if has("enabled") && enabled != row["enabled"].is(true) { return true }
        for f in DBServerField.allCases where has(f.key) {
            if text(f) != Self.fieldText(row, f) { return true }
        }
        return false
    }

    /// host:port, as a row without a label is named.
    static func address(_ row: JSON) -> String { "\(row["host"].string ?? ""):\(row["port"].int32 ?? 0)" }

    /// What a Test connection said when the server answered.
    static func testText(_ r: JSON) -> String {
        let claimed = r["claimedBy"]
        let dbs = r["databases"].int32 ?? 0
        let version = r["version"].string ?? "?"
        // Who holds it, when a session does: its title, else its id.
        var by = claimed.nonEmpty
        if by == nil && claimed.isObject { by = claimed["title"].nonEmpty ?? claimed["id"].nonEmpty }
        let holder = by.map { "claimed by session \($0)" } ?? (claimed.isObject ? "claimed by a session" : "free")
        return "Healthy: MySQL \(version), \(dbs) database\(dbs == 1 ? "" : "s") · \(holder)"
    }

    /// One open session with a database per server in the pool.
    static func poolCapacity(_ rows: [JSON]) -> Int { rows.filter { $0["enabled"].is(true) }.count }
    static func poolText(capacity n: Int, total: Int) -> String {
        let off = total > n ? " \(total - n) more \(total - n == 1 ? "is" : "are") listed but taken out of the pool." : ""
        return n > 0
            ? "\(n) server\(n == 1 ? "" : "s") in the pool, so \(n) session\(n == 1 ? "" : "s") with a database may be open at once.\(off)"
            : "No server is in the pool yet.\(off)"
    }
}
