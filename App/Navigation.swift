// Where a row or a button goes. The Mac app's detail pane holds one stack of screens beside its sidebar; a phone pushes
// the same screens on the stack of the tab they were opened from, and an iPad shows them in its right-hand column.
import SwiftUI

/// A screen another one can open. Each case's `id` names what it shows, so a repeated choice is not reopened.
enum Destination: Hashable, Identifiable {
    /// A project's conversations, with its board, findings and a new conversation above them.
    case project(repo: String)
    /// Conversations across every project this device can read.
    case allSessions
    /// A conversation; `session` is the record the list had, shown until the server answers.
    case conversation(id: String, session: JSON?)
    /// A project's board: pull requests and issues.
    case board(repo: String)
    /// The board across every project: pull requests, issues and the Review List.
    case globalBoard
    /// A pull request; `stack` is its StackPosition JSON and `summary` its board row, either nil when unknown.
    case pull(repo: String, number: Int, stack: JSON?, summary: JSON?)
    /// ▶ Run on the project's default branch, served in an embedded browser.
    case branchRun(repo: String)
    /// A pull request's changed files on their own.
    case pullFiles(repo: String, number: Int)
    /// An issue, with its board row.
    case issue(repo: String, issue: JSON)
    /// The review rounds waiting for a decision: one project's, or every project's with nil.
    case findings(repo: String?)
    /// What every project spent over a window.
    case usage
    /// The settings forms: `row` is the server's record (nil with `defaults` for a new one).
    case projectSettings(row: JSON?, defaults: JSON?)
    case providerSettings(row: JSON?, defaults: JSON?)
    case dbServerSettings(row: JSON?, defaults: JSON?)
    case sshServerSettings(row: JSON?, defaults: JSON?)
    case forgeAccountSettings(row: JSON?, defaults: JSON?)
    case slackWorkspaceSettings(row: JSON?, defaults: JSON?)
    /// A project's voice conversation, or a hands-free one held to one of its conversations.
    case voice(repo: String, conversation: VoiceConversation? = nil)
    /// The voice mode's ElevenLabs key and choices.
    case voiceSettings
    /// A session's ⚡ Webhook: its settings, URLs and keys.
    case webhook(session: JSON)
    /// A session's Resources: what it costs the machine; `session` is its record.
    case sessionStats(session: JSON)
    /// The Server dashboard: the machine, the Briareus process, its disks and the open sessions.
    case serverStats
    case sshMonitoring(serverID: Double?)
    case personalConnection(PersonalConnectionKind)
    case sharing
    /// A project's Laravel Forge servers and sites.
    case forge(repo: String)
    /// One Forge site: its overview, deploy script and .env. `account` is the Forge account's id.
    case forgeSite(repo: String, account: Double, server: JSON, site: JSON)

    var id: String {
        switch self {
        case .allSessions: return "all-sessions"
        case .project(let repo): return "project:\(repo)"
        case .conversation(let id, _): return "conversation:\(id)"
        case .board(let repo): return "pulls:\(repo)"
        case .globalBoard: return "global-pulls"
        case .pull(let repo, let n, _, _): return "pull:\(repo)#\(n)"
        case .pullFiles(let repo, let n): return "files:\(repo)#\(n)"
        case .branchRun(let repo): return "branch-run:\(repo)"
        case .issue(let repo, let issue): return "issue:\(repo)#\(issue["number"].int ?? 0)"
        case .findings(let repo): return "findings:\(repo ?? "")"
        case .usage: return "usage"
        case .projectSettings(let row, _): return "project-settings:\(row?["id"].int.map(String.init) ?? "new")"
        case .providerSettings(let row, _): return "provider-settings:\(row?["id"].int.map(String.init) ?? "new")"
        case .dbServerSettings(let row, _): return "db-server:\(row?["id"].int.map(String.init) ?? "new")"
        case .sshServerSettings(let row, _): return "ssh-server:\(row?["id"].int.map(String.init) ?? "new")"
        case .forgeAccountSettings(let row, _): return "forge-account:\(row?["id"].int.map(String.init) ?? "new")"
        case .slackWorkspaceSettings(let row, _): return "slack-workspace:\(row?["id"].int.map(String.init) ?? "new")"
        case .voice(let repo, let held): return "voice:\(repo)" + (held.map { ":\($0.id)" } ?? "")
        case .voiceSettings: return "voice-settings"
        case .webhook(let session): return "webhook:\(session["id"].string ?? "")"
        case .sessionStats(let session): return "session-stats:\(session["id"].string ?? "")"
        case .serverStats: return "server-stats"
        case .sshMonitoring(let id): return "ssh-monitoring:\(id.map { String($0) } ?? "all")"
        case .personalConnection(let kind): return "personal:\(kind.rawValue)"
        case .sharing: return "sharing"
        case .forge(let repo): return "forge:\(repo)"
        case .forgeSite(let repo, let account, let server, let site):
            return "forge-site:\(repo):" + String(format: "%.0f:%.0f:%.0f", account, server["id"].number ?? 0, site["id"].number ?? 0)
        }
    }
    static func == (a: Destination, b: Destination) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    @MainActor @ViewBuilder var screen: some View {
        switch self {
        case .allSessions: AllSessionsScreen()
        case .project(let repo): ProjectView(repo: repo)
        case .conversation(let id, let session): ConversationScreen(sessionID: id, initial: session)
        case .board(let repo): BoardScreen(repo: repo)
        case .globalBoard: GlobalPullsScreen()
        case .pull(let repo, let number, let stack, let summary): PullScreen(repo: repo, number: number, stack: stack, summary: summary)
        case .pullFiles(let repo, let number): PullFilesScreen(repo: repo, number: number)
        case .branchRun(let repo): BranchRunScreen(repo: repo)
        case .issue(let repo, let issue): IssueScreen(repo: repo, issue: issue)
        case .findings(let repo): FindingsScreen(repo: repo)
        case .usage: UsageEntry()
        case .projectSettings(let row, let defaults): ProjectSettingsScreen(row: row, defaults: defaults)
        case .providerSettings(let row, let defaults): ProviderSettingsScreen(row: row, defaults: defaults)
        case .dbServerSettings(let row, let defaults): DBServerSettingsScreen(row: row, defaults: defaults)
        case .sshServerSettings(let row, let defaults): SSHServerSettingsScreen(row: row, defaults: defaults)
        case .forgeAccountSettings(let row, let defaults): ForgeAccountSettingsScreen(row: row, defaults: defaults)
        case .slackWorkspaceSettings(let row, let defaults): SlackWorkspaceSettingsScreen(row: row, defaults: defaults)
        case .voice(let repo, let held): VoiceScreen(repo: repo, conversation: held)
        case .voiceSettings: VoiceSettingsScreen()
        case .webhook(let session): WebhookScreen(session: session)
        case .sessionStats(let session): SessionStatsScreen(session: session)
        case .serverStats: ServerStatsScreen()
        case .sshMonitoring(let id): SSHMonitoringScreen(serverID: id)
        case .personalConnection(let kind): PersonalConnectionScreen(kind: kind)
        case .sharing: SharingScreen()
        case .forge(let repo): ProjectForgeScreen(repo: repo)
        case .forgeSite(let repo, let account, let server, let site): ForgeSiteScreen(repo: repo, account: account, server: server, site: site)
        }
    }
}

/// Opens a destination: pushes it on the tab's stack, or on an iPad, puts it in the right-hand column.
struct Navigate {
    fileprivate var push: (Destination) -> Void
    func callAsFunction(_ destination: Destination) { push(destination) }
}

private struct NavigateKey: EnvironmentKey { static let defaultValue = Navigate { _ in } }
private struct DetailKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    /// Opens a screen from the one on show.
    var navigate: Navigate {
        get { self[NavigateKey.self] }
        set { self[NavigateKey.self] = newValue }
    }
    /// On an iPad's list column, the id of what the right-hand column shows ("" for nothing), so its row reads as
    /// selected; nil on a phone, where a row pushes.
    var detailSelection: String? {
        get { self[DetailKey.self] }
        set { self[DetailKey.self] = newValue }
    }
}

/// A navigation stack whose screens open others with `navigate`: what the tabs of a phone hold.
struct NavigationRoot<Root: View>: View {
    @ViewBuilder var root: () -> Root
    @State private var path: [Destination] = []
    var body: some View {
        NavigationStack(path: $path) {
            root().navigationDestination(for: Destination.self) { $0.screen }
        }
        .environment(\.navigate, Navigate { destination in
            if path.last != destination { path.append(destination) }
        })
    }
}

/// A list row that opens a destination: a push on a phone, a choice that reads as selected on an iPad's list column.
struct DestinationLink<Label: View>: View {
    let destination: Destination
    @ViewBuilder let label: () -> Label
    @Environment(\.navigate) private var navigate
    @Environment(\.detailSelection) private var selection
    var body: some View {
        if selection != nil {
            let selected = selection == destination.id
            Button { navigate(destination) } label: {
                label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Theme.row(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            NavigationLink(value: destination, label: label).listRowBackground(Theme.row)
        }
    }
}

/// An iPad's Projects tab: the projects and a project's conversations on the left, the chosen screen on the right with
/// its own stack, as the Mac app lays them out.
struct SplitRoot: View {
    @State private var detail: Destination?
    @State private var detailPath: [Destination] = []
    @State private var listPath: [Destination] = []
    @State private var columns = NavigationSplitViewVisibility.all
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            NavigationStack(path: $listPath) {
                ProjectsList().navigationDestination(for: Destination.self) { $0.screen }
            }
            .environment(\.detailSelection, detail?.id ?? "")
            .environment(\.navigate, Navigate { destination in
                // Session lists open in the list column; conversation details fill the right-hand side.
                switch destination {
                case .project, .allSessions:
                    if listPath.last != destination { listPath.append(destination) }
                default: detail = destination; detailPath = []
                }
            })
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
            // The two sides share a background, so a rule marks where the list ends.
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 0.5).ignoresSafeArea() }
        } detail: {
            NavigationStack(path: $detailPath) {
                Group {
                    if let detail { detail.screen } else {
                        ContentUnavailableView("No conversation selected", systemImage: "bubble.left.and.text.bubble.right",
                                               description: Text("Choose a conversation from the list to read it here."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas)
                    }
                }
                .navigationDestination(for: Destination.self) { $0.screen }
            }
            // Another choice starts from its own first screen rather than under what was pushed on the last.
            .id(detail?.id)
            .environment(\.navigate, Navigate { destination in
                if detailPath.last != destination { detailPath.append(destination) }
            })
        }
        .navigationSplitViewStyle(.balanced)
    }
}
