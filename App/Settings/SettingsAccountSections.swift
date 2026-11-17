// The Settings tab's account sections, under the SSH servers: the GitHub accounts, the Forge accounts and the Slack
// workspaces, each row with its icon (tinted while a token is stored), label, what it is and its projects, and ＋. The
// Settings tab shows each only on a server whose catalog lists it, as the Mac settings sidebar does.
import SwiftUI

/// The GitHub accounts the server reads and writes GitHub with for their projects (core #317).
struct GithubAccountsSection: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var lists = SettingsLists.shared
    @Environment(\.navigate) private var navigate
    var body: some View {
        let s = lists.github
        Section {
            if let error = s.error { ErrorNotice(message: error) }
            ForEach(Array(s.list.enumerated()), id: \.offset) { _, row in
                DestinationLink(destination: .githubAccountSettings(row: row)) {
                    SettingsItemRow(title: GithubAccountFormState.title(row),
                                    subtitle: GithubAccountFormState.sidebarLine(row), on: row["hasToken"].is(true),
                                    systemImage: "person")
                }
            }
            if !s.loaded { SettingsLoadingRow(text: "Loading GitHub accounts…") }
        } header: {
            SettingsSectionHeader(title: "GitHub accounts", newLabel: "New GitHub account",
                                  onNew: store.supports("create_github_account") ? { navigate(.githubAccountSettings(row: nil)) } : nil)
        } footer: {
            if s.loaded && s.list.isEmpty && s.error == nil {
                Text("No GitHub accounts yet. ＋ adds a GitHub token and the projects the server uses it for.")
            }
        }
        .listRowBackground(Theme.row)
    }
}

/// The Forge accounts: each with its label, organization and projects.
struct ForgeAccountsSection: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var lists = SettingsLists.shared
    @Environment(\.navigate) private var navigate
    var body: some View {
        let s = lists.forge
        Section {
            if let error = s.error { ErrorNotice(message: error) }
            ForEach(Array(s.list.enumerated()), id: \.offset) { _, row in
                DestinationLink(destination: .forgeAccountSettings(row: row, defaults: s.defaults)) {
                    SettingsItemRow(title: row["label"].nonEmpty ?? row["organization"].nonEmpty ?? "Forge account",
                                    subtitle: ForgeAccountFormState.sidebarLine(row), on: row["hasToken"].is(true), systemImage: "cloud")
                }
            }
            if !s.loaded { SettingsLoadingRow(text: "Loading Forge accounts…") }
        } header: {
            SettingsSectionHeader(title: "Forge accounts", newLabel: "New Forge account",
                                  onNew: store.supports("create_forge_account") ? { navigate(.forgeAccountSettings(row: nil, defaults: s.defaults)) } : nil)
        } footer: {
            if s.loaded && s.list.isEmpty && s.error == nil {
                Text("No Forge accounts yet. ＋ adds a Laravel Forge organization and the projects that may use it.")
            }
        }
        .listRowBackground(Theme.row)
    }
}

/// The Slack workspaces under the Forge accounts: each with its label, workspace and projects.
struct SlackWorkspacesSection: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var lists = SettingsLists.shared
    @Environment(\.navigate) private var navigate
    var body: some View {
        let s = lists.slack
        Section {
            if let error = s.error { ErrorNotice(message: error) }
            ForEach(Array(s.list.enumerated()), id: \.offset) { _, row in
                DestinationLink(destination: .slackWorkspaceSettings(row: row, defaults: s.defaults)) {
                    SettingsItemRow(title: row["label"].nonEmpty ?? row["team"].nonEmpty ?? "Slack workspace",
                                    subtitle: SlackWorkspaceFormState.sidebarLine(row), on: row["hasToken"].is(true),
                                    systemImage: "bubble.left.and.text.bubble.right")
                }
            }
            if !s.loaded { SettingsLoadingRow(text: "Loading Slack workspaces…") }
        } header: {
            SettingsSectionHeader(title: "Slack workspaces", newLabel: "New Slack workspace",
                                  onNew: store.supports("create_slack_workspace") ? { navigate(.slackWorkspaceSettings(row: nil, defaults: s.defaults)) } : nil)
        } footer: {
            if s.loaded && s.list.isEmpty && s.error == nil {
                Text("No Slack workspaces yet. ＋ lets a project's sessions send Slack messages as you and hear the replies.")
            }
        }
        .listRowBackground(Theme.row)
    }
}
