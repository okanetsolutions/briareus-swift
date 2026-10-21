// The detail pane's screens: which view draws each `Screen` the navigator holds.
import SwiftUI

/// The view for each screen.
struct ScreenView: View {
    var screen: Screen
    var body: some View {
        switch screen {
        case .placeholder: PlaceholderScreen()
        case .newSession(let repo): NewSessionScreen(repo: repo)
        case .conversation(let id, let session): ConversationScreen(sessionID: id, initial: session)
        case .board(let repo): BoardScreen(repo: repo)
        case .pull(let repo, let number, let stack, let summary): PullScreen(repo: repo, number: number, stack: stack, summary: summary)
        case .pullFiles(let repo, let number): PullFilesScreen(repo: repo, number: number)
        case .issue(let repo, let issue): IssueScreen(repo: repo, issue: issue)
        case .findings: FindingsScreen()
        case .usage: UsageScreen()
        case .status: StatusScreen()
        case .webApp(let app): WebAppScreen(app: app)
        case .projectSettings(let row, let defaults): ProjectSettingsScreen(row: row, defaults: defaults)
        case .providerSettings(let row, let defaults): ProviderSettingsScreen(row: row, defaults: defaults)
        case .dbServerSettings(let row, let defaults): DBServerSettingsScreen(row: row, defaults: defaults)
        case .sshServerSettings(let row, let defaults): SSHServerSettingsScreen(row: row, defaults: defaults)
        case .forgeAccountSettings(let row, let defaults): ForgeAccountSettingsScreen(row: row, defaults: defaults)
        case .slackWorkspaceSettings(let row, let defaults): SlackWorkspaceSettingsScreen(row: row, defaults: defaults)
        case .mcpServerSettings(let row, let defaults): McpServerSettingsScreen(row: row, defaults: defaults)
        case .envoyerAccountSettings(let row, let defaults): EnvoyerAccountSettingsScreen(row: row, defaults: defaults)
        case .meetingSettings: MeetingSettingsScreen()
        case .mailSettings(let id): MailSettingsScreen(accountID: id).id(id ?? 0)
        case .mail: MailScreen()
        case .serverSettings: ServerSettingsScreen()
        case .templatesSettings: TemplatesSettingsScreen()
        case .webhook(let session): WebhookScreen(session: session)
        case .mailWake(let session): MailWakeScreen(session: session)
        case .sessionStats(let session): SessionStatsScreen(session: session)
        case .serverStats: ServerStatsScreen()
        case .sshServers: SSHServersScreen()
        }
    }
}
