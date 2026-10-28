// What the detail pane can show (Screen); ScreenView.swift draws each and the Navigator (Navigation.swift) keeps a stack
// of them.
import SwiftUI

/// The web apps the sidebar strip opens in the detail pane.
enum WebApp: String, Hashable, CaseIterable { case whatsapp }

/// What the detail pane shows. Each case's `id` names what it shows, so a repeated choice is not reopened.
enum Screen: Hashable, Identifiable {
    case placeholder
    /// The Windows client's opening view: Welcome back, and the composer that starts a session on a project.
    case newSession(repo: String?)
    /// A conversation; `session` is the record the sidebar had, shown until the server answers.
    case conversation(id: String, session: JSON?)
    /// A project's board: pull requests, issues, SSH sessions and SFTP sessions as tabs.
    case board(repo: String)
    /// Open pull requests across all projects this token can read.
    case globalPulls
    /// A pull request; `stack` is its StackPosition JSON and `summary` its board row, either nil when unknown.
    case pull(repo: String, number: Int, stack: JSON?, summary: JSON?)
    /// The changed files on their own, for the conversation's menu.
    case pullFiles(repo: String, number: Int)
    /// An issue, with its board row.
    case issue(repo: String, issue: JSON)
    /// The review rounds waiting for a decision across every project.
    case findings
    /// What every project spent over a window.
    case usage
    /// The conversations waiting for you, with their questions to answer, and those working now.
    case status
    case webApp(WebApp)
    /// The settings page's forms: `row` is the server's record (nil with `defaults` for a new one).
    case projectSettings(row: JSON?, defaults: JSON?)
    case providerSettings(row: JSON?, defaults: JSON?)
    case dbServerSettings(row: JSON?, defaults: JSON?)
    case sshServerSettings(row: JSON?, defaults: JSON?)
    case forgeAccountSettings(row: JSON?, defaults: JSON?)
    case slackWorkspaceSettings(row: JSON?, defaults: JSON?)
    case mcpServerSettings(row: JSON?, defaults: JSON?)
    case envoyerAccountSettings(row: JSON?, defaults: JSON?)
    /// This Mac's meeting assistant settings.
    case meetingSettings
    /// A mailbox the server keeps synced, or (nil) adding one.
    case mailSettings(id: Int?)
    /// The synced mail.
    case mail
    /// The server's maintenance and workspaces, and its prompt templates.
    case serverSettings
    case templatesSettings
    /// A session's ⚡ Webhook, pushed over its conversation; `session` is the conversation's record.
    case webhook(session: JSON)
    /// A session's ✉ Mail wake rules, pushed over its conversation as the webhook is.
    case mailWake(session: JSON)
    /// A session's Resources, pushed over its conversation or from the Server dashboard; `session` is its record.
    case sessionStats(session: JSON)
    /// The Server dashboard: the machine, the Briareus process, its disks and the open sessions.
    case serverStats
    case sshMonitoring(serverID: Double?)
    case personalConnection(PersonalConnectionKind)
    case sharing
    /// Every registered SSH server in a folder per project, and the open SSH sessions.
    case sshServers

    var id: String {
        switch self {
        case .placeholder: return "placeholder"
        case .newSession(let repo): return "new:\(repo ?? "")"
        case .conversation(let id, _): return "conversation:\(id)"
        case .board(let repo): return "pulls:\(repo)"
        case .globalPulls: return "global-pulls"
        case .pull(let repo, let n, _, _): return "pull:\(repo)#\(n)"
        case .pullFiles(let repo, let n): return "files:\(repo)#\(n)"
        case .issue(let repo, let issue): return "issue:\(repo)#\(issue["number"].int ?? 0)"
        case .findings: return "findings"
        case .usage: return "usage"
        case .status: return "status"
        case .webApp(let app): return app.rawValue
        case .projectSettings(let row, _): return "project-settings:\(row?["id"].int.map(String.init) ?? "new")"
        case .providerSettings(let row, _): return "provider-settings:\(row?["id"].int.map(String.init) ?? "new")"
        case .dbServerSettings(let row, _): return "db-server:\(row?["id"].int.map(String.init) ?? "new")"
        case .sshServerSettings(let row, _): return "ssh-server:\(row?["id"].int.map(String.init) ?? "new")"
        case .forgeAccountSettings(let row, _): return "forge-account:\(row?["id"].int.map(String.init) ?? "new")"
        case .slackWorkspaceSettings(let row, _): return "slack-workspace:\(row?["id"].int.map(String.init) ?? "new")"
        case .mcpServerSettings(let row, _): return "mcp-server:\(row?["id"].int.map(String.init) ?? "new")"
        case .envoyerAccountSettings(let row, _): return "envoyer-account:\(row?["id"].int.map(String.init) ?? "new")"
        case .meetingSettings: return "settings-meeting"
        case .mailSettings(let id): return id.map { "mail-settings:\($0)" } ?? "mail-settings"
        case .mail: return "mail"
        case .serverSettings: return "settings-server"
        case .templatesSettings: return "settings-templates"
        case .webhook(let session): return "webhook:\(session["id"].string ?? "")"
        case .mailWake(let session): return "mail-wake:\(session["id"].string ?? "")"
        case .sessionStats(let session): return "session-stats:\(session["id"].string ?? "")"
        case .serverStats: return "server-stats"
        case .sshMonitoring(let id): return "ssh-monitoring:\(id.map { String($0) } ?? "all")"
        case .personalConnection(let kind): return "personal:\(kind.rawValue)"
        case .sharing: return "sharing"
        case .sshServers: return "ssh-servers"
        }
    }
    static func == (a: Screen, b: Screen) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}
