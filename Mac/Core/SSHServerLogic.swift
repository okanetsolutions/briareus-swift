// The SSH server form's fields and what a save sends: the form keeps the row it was filled from and the text of every
// box. The server's database login is read on demand, and the SSH and sudo passwords are write-only: the server never
// sends them back, so their boxes start empty and a save with one empty keeps the stored one.
import Foundation

enum SSHServerTab: Int, CaseIterable, Sendable {
    case server, database
    var title: String { self == .server ? "SSH server" : "Database" }
}

enum SSHServerField: Int, CaseIterable, Sendable {
    case label, host, port, username, key, password, sudoPassword, dbHost, dbPort, dbUsername, dbPassword
    var def: SettingsField {
        switch self {
        case .label: return SettingsField(key: "label", kind: .text, label: "Label", cue: "Production web server", hint: "Leave empty to name it user@host:port.")
        case .host: return SettingsField(key: "host", kind: .text, label: "Host", cue: "server.example.com", mono: true)
        case .port: return SettingsField(key: "port", kind: .number, label: "Port", cue: "22", mono: true)
        case .username: return SettingsField(key: "username", kind: .text, label: "Username", cue: "deploy", mono: true)
        case .key: return SettingsField(key: "identityFile", kind: .text, label: "Private key path", cue: "/home/you/.ssh/id_ed25519",
            hint: "Absolute path on the machine running Briareus; leave empty for its default SSH keys or agent. Not used while a password is stored.", mono: true)
        case .password: return SettingsField(key: "password", kind: .text, label: "Password", cue: "empty = key authentication",
            hint: "Signs in with this password instead of a key. Stored encrypted and never shown again.", mono: true, secret: true)
        case .sudoPassword: return SettingsField(key: "sudoPassword", kind: .text, label: "Sudo password", cue: "empty = no sudo",
            hint: "Lets agents run a command as root. Root commands follow the permission mode like any other, so with Don’t ask anything they run without approval. Separate from the SSH login; stored encrypted and never shown again.",
            mono: true, secret: true)
        case .dbHost: return SettingsField(key: "dbHost", kind: .text, label: "Database host", cue: "127.0.0.1",
            hint: "Where the database listens, as seen from the SSH server itself. Leave empty for 127.0.0.1.", mono: true)
        case .dbPort: return SettingsField(key: "dbPort", kind: .number, label: "Database port", cue: "3306", mono: true)
        case .dbUsername: return SettingsField(key: "dbUsername", kind: .text, label: "Database username", cue: "app",
            hint: "Leave empty to keep no login on this server.", mono: true)
        case .dbPassword: return SettingsField(key: "dbPassword", kind: .text, label: "Database password", cue: "empty = no password",
            hint: "Sent as typed, spaces included. Leave empty for a user without a password.", mono: true, secret: true)
        }
    }
    var key: String { def.key ?? "" }
    var tab: SSHServerTab { rawValue >= Self.dbHost.rawValue ? .database : .server }
    /// The login's two boxes, which the server's rows never carry: it keeps them sealed and opens them only through
    /// GET …/db-credentials.
    var isLogin: Bool { self == .dbUsername || self == .dbPassword }
    /// The passwords the server keeps sealed and never sends back: its rows only say whether one is stored
    /// (`hasPassword`, `hasSudoPassword`). Empty keeps the stored one; typed replaces it; removed sends "".
    var isWriteOnly: Bool { self == .password || self == .sudoPassword }
    /// The row's flag for a write-only box.
    var storedKey: String { self == .password ? "hasPassword" : "hasSudoPassword" }
    static func on(_ t: SSHServerTab) -> [SSHServerField] { allCases.filter { $0.tab == t } }
}

/// An SSH server's database login, as the server opened it.
struct DBLogin: Equatable, Sendable {
    var username = ""
    var password = ""
}

struct SSHServerFormState: Equatable, Sendable {
    var row: JSON
    var texts: [SSHServerField: String] = [:]
    /// Available to sessions on this project.
    var enabled = true
    var monitoringEnabled = false
    var offersMonitoring: Bool { row.object?["monitoringEnabled"] != nil }
    var repo = ""
    var mode = "ask"
    var dirty = false
    /// The login stored on the server, once it is known: read through GET …/db-credentials, or none stored.
    var login = DBLogin()
    var loginKnown = true
    /// The stored passwords to remove on save.
    var clear: Set<SSHServerField> = []

    /// A new server starts on the first project, as the web's form does, on port 22; on a server that stores a database
    /// login (`database`), with the database where the server's own default puts it; with the passwords the server takes
    /// (`passwords`), none of them stored.
    init(row: JSON, firstRepo: String? = nil, database: Bool = false, passwords: Set<SSHServerField> = []) {
        var r: JSON = row.isObject ? row : [:]
        if Self.rowID(r) == 0 {
            if r["repo"].nonEmpty == nil, let firstRepo, !firstRepo.isEmpty { r["repo"] = .string(firstRepo) }
            if r.object?["port"] == nil { r["port"] = 22 }
            if database && r.object?["dbHost"] == nil { r["dbHost"] = "127.0.0.1" }
            if database && r.object?["dbPort"] == nil { r["dbPort"] = 3306 }
            for f in passwords where f.isWriteOnly && r.object?[f.storedKey] == nil { r[f.storedKey] = false }
        }
        self.row = r
        loginKnown = !hasLogin
        fill()
    }

    /// An SSH server's id is the time it was registered in milliseconds, past what an int holds.
    static func rowID(_ row: JSON) -> Double { row["id"].number.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
    var id: Double { Self.rowID(row) }
    func text(_ f: SSHServerField) -> String { texts[f] ?? "" }
    /// The server stores a database login per SSH server: its rows say where the database listens.
    var offersDatabase: Bool { row.object?["dbHost"] != nil }
    var hasLogin: Bool { row["hasDbCredentials"].is(true) }
    /// The server takes this password: its rows say whether one is stored. Each is asked on its own, as the server
    /// took SSH passwords before sudo ones.
    func offers(_ f: SSHServerField) -> Bool { f.isWriteOnly && row.object?[f.storedKey] != nil }
    /// The server takes either password, for the section that holds them.
    var offersPasswords: Bool { offers(.password) || offers(.sudoPassword) }
    func stored(_ f: SSHServerField) -> Bool { f.isWriteOnly && row[f.storedKey].is(true) }
    /// A tab's boxes as the form shows them: each password only on a server that takes it.
    func fields(on t: SSHServerTab) -> [SSHServerField] { SSHServerField.on(t).filter { !$0.isWriteOnly || offers($0) } }
    /// The passwords a server takes, from its list: those any row says whether one is stored. An empty list cannot
    /// tell, and is taken as a current server's.
    static func takesPasswords(_ rows: [JSON]) -> Set<SSHServerField> {
        Set(SSHServerField.allCases.filter { f in f.isWriteOnly && (rows.isEmpty || rows.contains { $0.object?[f.storedKey] != nil }) })
    }
    /// What a write-only box says while it is empty: that it is removed on save, that one is stored, or its own cue.
    func cue(_ f: SSHServerField) -> String? {
        if clear.contains(f) { return "Removed on save" }
        if stored(f) { return "Stored · type a new one to replace it" }
        return f.def.cue
    }
    /// A box's new text. A password typed replaces the stored one rather than removing it.
    mutating func setText(_ f: SSHServerField, _ value: String) {
        texts[f] = value
        if !value.isEmpty { clear.remove(f) }
    }
    /// Marks a stored password for removal on save, emptying its box, or takes the mark back.
    mutating func toggleClear(_ f: SSHServerField) {
        guard f.isWriteOnly else { return }
        if clear.contains(f) { clear.remove(f) } else { clear.insert(f); texts[f] = "" }
    }

    static func savedRepo(_ row: JSON) -> String { row["repo"].nonEmpty ?? "" }
    /// A server without a mode asks, as the server's own default does.
    static func savedMode(_ row: JSON) -> String { row["permissionMode"].nonEmpty ?? "ask" }
    static func savedEnabled(_ row: JSON) -> Bool { !row["enabled"].is(false) }
    static func modeTitle(_ mode: String) -> String { mode == "allow" ? "Don’t ask anything" : "Ask for all commands" }

    mutating func fill() {
        enabled = Self.savedEnabled(row)
        monitoringEnabled = row["monitoringEnabled"].is(true)
        repo = Self.savedRepo(row)
        mode = Self.savedMode(row)
        // A clone's row carries the login and passwords it was copied with; a saved one only says whether there are any.
        for f in SSHServerField.allCases {
            texts[f] = f.isLogin || f.isWriteOnly ? row[f.key].string ?? savedText(f) : Self.fieldText(row, f)
        }
        clear = []
        dirty = false
    }
    static func fieldText(_ row: JSON, _ f: SSHServerField) -> String {
        if f.isWriteOnly { return "" }
        return f.def.kind == .number ? SettingsText.numberText(row[f.key]) : row[f.key].string ?? ""
    }
    /// A box's value as saved: the login's as last read, the others as the row has them.
    func savedText(_ f: SSHServerField) -> String {
        switch f {
        case .dbUsername: return login.username
        case .dbPassword: return login.password
        default: return Self.fieldText(row, f)
        }
    }

    /// The login read through GET …/db-credentials, into the boxes not typed in yet.
    mutating func loginRead(_ credentials: JSON) {
        let was = login
        login = DBLogin(username: credentials["username"].string ?? "", password: credentials["password"].string ?? "")
        loginKnown = true
        if text(.dbUsername) == was.username { texts[.dbUsername] = login.username }
        if text(.dbPassword) == was.password { texts[.dbPassword] = login.password }
    }

    func body() -> Result<JSON, FormProblem> {
        var body: JSON = row.isObject ? row : [:]
        for k in ["id", "hasDbCredentials", "dbUsername", "dbPassword", "password", "sudoPassword", "hasPassword", "hasSudoPassword"] {
            body.remove(k)
        }
        for f in SSHServerField.on(.server) where !f.isWriteOnly {
            let t = text(f).cTrimmed
            if f.def.kind == .number {
                guard let port = SettingsText.port(t) else { return .failure(FormProblem(message: "Enter a port from 1 to 65535.")) }
                body[f.key] = JSON(port)
            } else { body[f.key] = .string(t) }
        }
        body["repo"] = .string(repo)
        body["permissionMode"] = .string(mode)
        body["enabled"] = .bool(enabled)
        if offersMonitoring { body["monitoringEnabled"] = .bool(monitoringEnabled) }
        if (body["repo"].string ?? "").isEmpty { return .failure(FormProblem(message: "Choose the project whose sessions may use this server.")) }
        if (body["host"].string ?? "").isEmpty { return .failure(FormProblem(message: "Enter the host: a hostname or an IP address.")) }
        if (body["username"].string ?? "").isEmpty { return .failure(FormProblem(message: "Enter the username to connect as.")) }
        // Only what changed is sent, as typed: spaces may belong to a password. Left out, the stored one stays.
        for f in [SSHServerField.password, .sudoPassword] where offers(f) {
            let t = text(f)
            if clear.contains(f) { body[f.key] = ""; continue }
            if t.isEmpty { continue }
            if let problem = Self.passwordProblem(t, f) { return .failure(FormProblem(message: problem)) }
            body[f.key] = .string(t)
        }
        if offersDatabase {
            let database = SSHServerTab.database.rawValue
            body["dbHost"] = .string(text(.dbHost).cTrimmed)
            guard let port = SettingsText.port(text(.dbPort).cTrimmed) else {
                return .failure(FormProblem(message: "Enter a database port from 1 to 65535.", tab: database))
            }
            body["dbPort"] = JSON(port)
            // Only what changed is sent: the server keeps the half of the login left out, and an empty username removes
            // it, password and all. A password spaces may belong to is sent as typed.
            let user = text(.dbUsername).cTrimmed, pass = text(.dbPassword)
            if user.isEmpty && loginKnown {
                if !pass.isEmpty && pass != login.password {
                    return .failure(FormProblem(message: "Enter the database username this password is for.", tab: database))
                }
                if !login.username.isEmpty { body["dbUsername"] = ""; body["dbPassword"] = "" }
            } else {
                if user != login.username { body["dbUsername"] = .string(user) }
                if pass != login.password { body["dbPassword"] = .string(pass) }
            }
        }
        return .success(body)
    }

    /// Why the server would refuse a password: more than its askpass helper passes on (1023 UTF-8 bytes), or a NUL or a
    /// line break in it.
    static func passwordProblem(_ text: String, _ f: SSHServerField) -> String? {
        let name = f == .sudoPassword ? "The sudo password" : "The SSH password"
        if text.utf8.count > 1023 { return "\(name) is too long: at most 1023 bytes." }
        if text.unicodeScalars.contains(where: { $0 == "\0" || $0 == "\r" || $0 == "\n" }) { return "\(name) cannot hold a line break or a NUL character." }
        return nil
    }

    /// The server's word on what was saved, from the body sent: what the login is now, when the form knows all of it.
    mutating func saved(_ newRow: JSON, sent body: JSON) {
        let user = body["dbUsername"].string, pass = body["dbPassword"].string
        row = newRow
        if !hasLogin {
            login = DBLogin(); loginKnown = true
        } else if user != nil || pass != nil {
            if loginKnown || (user != nil && pass != nil) {
                login = DBLogin(username: user ?? login.username, password: pass ?? login.password); loginKnown = true
            } else {
                login = DBLogin(); loginKnown = false
            }
        }
        fill()
    }

    /// What a clone starts from: the form as it stands, its login included, without the label that named this one.
    func copy() -> Result<JSON, FormProblem> {
        body().map { b in
            var copy = b
            copy["label"] = ""
            for f in [SSHServerField.dbUsername, .dbPassword, .password, .sudoPassword] { copy.remove(f.key) }
            // The passwords typed go with it; stored ones cannot, as they are never read back.
            for f in [SSHServerField.password, .sudoPassword] where offers(f) && !text(f).isEmpty { copy[f.key] = .string(text(f)) }
            if offersDatabase && !text(.dbUsername).cTrimmed.isEmpty {
                copy["dbUsername"] = .string(text(.dbUsername).cTrimmed)
                copy["dbPassword"] = .string(text(.dbPassword))
            }
            return copy
        }
    }

    /// Whether the form holds a change not saved yet, for the dot after the tab's title.
    var changed: Bool { SSHServerTab.allCases.contains { tabChanged($0) } }
    func tabChanged(_ t: SSHServerTab) -> Bool {
        if t == .server && (enabled != Self.savedEnabled(row) || monitoringEnabled != row["monitoringEnabled"].is(true) || repo != Self.savedRepo(row) || mode != Self.savedMode(row) || !clear.isEmpty) {
            return true
        }
        if t == .database && !offersDatabase { return false }
        return SSHServerField.on(t).contains { text($0) != savedText($0) }
    }

    /// The header's subtitle for a saved server: user@host:port · project.
    static func subtitle(_ row: JSON) -> String {
        let user = row["username"].nonEmpty, host = row["host"].nonEmpty ?? "", repo = row["repo"].nonEmpty ?? ""
        return "\(user.map { "\($0)@" } ?? "")\(host):\(fieldText(row, .port)) · \(repo)"
    }
}

// MARK: - The SSH servers page

/// A project's folder on the SSH servers page: the servers registered for it, in Settings' order.
struct SSHServerFolder: Equatable, Sendable, Identifiable {
    /// The project's repository; "" for the servers registered for no project.
    var repo: String
    /// The project's label, else its repository; nil for the servers registered for no project.
    var title: String?
    var servers: [JSON]
    var id: String { repo }
}

/// The SSH servers page's folders: one per project that has servers, in the sidebar's order (`projects`), then projects
/// the sidebar does not list by repository, then the servers with no project. `query` keeps the servers whose label, host
/// or username holds it, and every server of a project whose title or repository holds it; a folder left empty goes.
func sshServerFolders(_ servers: [JSON], projects: [Project], query: String = "") -> [SSHServerFolder] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    func holds(_ text: String?) -> Bool { q.isEmpty || (text ?? "").range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    var byRepo: [String: [JSON]] = [:]
    for s in servers { byRepo[s["repo"].string ?? "", default: []].append(s) }
    let listed = projects.map(\.repo).filter { byRepo[$0] != nil && !$0.isEmpty }
    let unlisted = byRepo.keys.filter { !$0.isEmpty && !listed.contains($0) }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    let order = listed + unlisted + (byRepo[""] != nil ? [""] : [])
    return order.compactMap { repo in
        let title: String? = repo.isEmpty ? nil : projects.first { $0.repo == repo }?.title ?? repo
        let all = byRepo[repo] ?? []
        let kept = !repo.isEmpty && (holds(title) || holds(repo)) ? all
            : all.filter { holds($0["label"].string) || holds($0["host"].string) || holds($0["username"].string) }
        return kept.isEmpty ? nil : SSHServerFolder(repo: repo, title: title, servers: kept)
    }
}

/// Whether the SSH servers page's search holds anything.
func sshServerSearching(_ query: String) -> Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

/// Whether a project's folder shows its servers: unless it is folded shut (`folded`, by repository), and always while
/// searching, so a match is never hidden.
func sshServerFolderOpen(_ repo: String, folded: Set<String>, query: String) -> Bool {
    sshServerSearching(query) || !folded.contains(repo)
}

/// The folded folders after a click on a project's folder line: it folds shut or opens. While searching every folder
/// shows open, so a click changes nothing rather than one that shows only once the search is cleared.
func sshServerFolderToggled(_ repo: String, folded: Set<String>, query: String) -> Set<String> {
    if sshServerSearching(query) { return folded }
    var next = folded
    if next.contains(repo) { next.remove(repo) } else { next.insert(repo) }
    return next
}

/// The tab labels on the SSH servers page, which shows every project's sessions in one row: each session's own label
/// (`TermTarget.tabLabel`), with its project's title after it when a session of another project has the same label.
func sshSessionTabLabels(_ targets: [TermTarget], projects: [Project]) -> [String] {
    targets.map { t in
        let clash = targets.contains { $0.tabLabel == t.tabLabel && $0.group != t.group }
        guard clash, !t.group.isEmpty else { return t.tabLabel }
        return "\(t.tabLabel) \u{00B7} \(projects.first { $0.repo == t.group }?.title ?? t.group)"
    }
}
