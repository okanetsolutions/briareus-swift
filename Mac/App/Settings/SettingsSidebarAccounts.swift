// The settings sidebar's account sections, under the SSH servers: the GitHub accounts, the Forge accounts and the Slack
// workspaces, each with its dot (a token is stored), label, what it is and its projects, and ＋ New. SettingsSidebar.swift
// shows each only on a server whose catalog lists it.
import SwiftUI

/// The GitHub accounts the server reads and writes GitHub with for their projects (core #317).
struct GithubAccountRows: View {
    var selected: String?
    @EnvironmentObject private var store: Store
    @ObservedObject private var model = GithubAccountsModel.shared
    var body: some View {
        Color.clear.frame(height: 8)
        SectionHeader(title: "GitHub accounts", onNew: store.supports("create_github_account") ? { model.new() } : nil)
        let s = model.section
        if let error = s.error { Notice(message: error).padding(.horizontal, 8).padding(.bottom, 8) }
        ForEach(Array(s.list.enumerated()), id: \.offset) { _, row in
            ItemRow(label: GithubAccountFormState.title(row), sub: GithubAccountFormState.sidebarLine(row),
                    enabled: row["hasToken"].is(true), selected: selected == Screen.githubAccountSettings(row: row).id) { model.open(row) }
        }
        // An account being added shows as its own row until it is saved.
        if selected == "github-account:new" { ItemRow(label: "New GitHub account", sub: "not saved yet", enabled: false, selected: true) {} }
        if s.loaded && s.list.isEmpty && s.error == nil {
            SettingsExplanation(text: "No GitHub accounts yet. ＋ New adds a GitHub token and the projects the server uses it for.")
        }
        if !s.loaded { LoadingNote(text: "Loading GitHub accounts…") }
    }
}

/// The Forge accounts: each with its dot (a token is stored), label, organization and projects.
struct ForgeAccountRows: View {
    var selected: String?
    @EnvironmentObject private var store: Store
    @ObservedObject private var model = SettingsModel.shared
    var body: some View {
        Color.clear.frame(height: 8)
        SectionHeader(title: "Forge accounts", onNew: store.supports("create_forge_account") ? { model.newForge() } : nil)
        let s = model.forge
        if let error = s.error { Notice(message: error).padding(.horizontal, 8).padding(.bottom, 8) }
        ForEach(Array(s.list.enumerated()), id: \.offset) { i, row in
            ItemRow(label: row["label"].nonEmpty ?? row["organization"].nonEmpty ?? "Forge account", sub: ForgeAccountFormState.sidebarLine(row),
                    enabled: row["hasToken"].is(true), selected: selected == Screen.forgeAccountSettings(row: row, defaults: nil).id) { model.openForge(i) }
        }
        // An account being added shows as its own row until it is saved.
        if selected == "forge-account:new" { ItemRow(label: "New Forge account", sub: "not saved yet", enabled: false, selected: true) {} }
        if s.loaded && s.list.isEmpty && s.error == nil {
            SettingsExplanation(text: "No Forge accounts yet. ＋ New adds a Laravel Forge organization and the projects that may use it.")
        }
        if !s.loaded { LoadingNote(text: "Loading Forge accounts…") }
    }
}

/// The Slack workspaces under the Forge accounts: each with its dot (a token is stored), label, workspace and projects.
struct SlackWorkspaceRows: View {
    var selected: String?
    @EnvironmentObject private var store: Store
    @ObservedObject private var model = SettingsModel.shared
    var body: some View {
        Color.clear.frame(height: 8)
        SectionHeader(title: "Slack workspaces", onNew: store.supports("create_slack_workspace") ? { model.newSlack() } : nil)
        let s = model.slack
        if let error = s.error { Notice(message: error).padding(.horizontal, 8).padding(.bottom, 8) }
        ForEach(Array(s.list.enumerated()), id: \.offset) { i, row in
            ItemRow(label: row["label"].nonEmpty ?? row["team"].nonEmpty ?? "Slack workspace", sub: SlackWorkspaceFormState.sidebarLine(row),
                    enabled: row["hasToken"].is(true), selected: selected == Screen.slackWorkspaceSettings(row: row, defaults: nil).id) { model.openSlack(i) }
        }
        // A workspace being added shows as its own row until it is saved.
        if selected == "slack-workspace:new" { ItemRow(label: "New Slack workspace", sub: "not saved yet", enabled: false, selected: true) {} }
        if s.loaded && s.list.isEmpty && s.error == nil {
            SettingsExplanation(text: "No Slack workspaces yet. ＋ New lets a project's sessions send Slack messages as you and hear the replies.")
        }
        if !s.loaded { LoadingNote(text: "Loading Slack workspaces…") }
    }
}
