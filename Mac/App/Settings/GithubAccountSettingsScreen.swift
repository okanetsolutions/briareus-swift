// A GitHub account across the whole pane in one tab, built from the Forge account form's pieces: its label and write-only
// token, what GitHub said about the stored token (login, user id, classic scopes; a fine-grained token reports none), and
// the projects it serves, one tick box each, a project another account serves marked. Saved through
// /settings/github/accounts, which needs an Admin token.
import SwiftUI

struct GithubAccountSettingsScreen: View {
    var row: JSON?
    @StateObject private var model: GithubAccountFormModel
    @ObservedObject private var settings = SettingsModel.shared
    @ObservedObject private var accounts = GithubAccountsModel.shared
    @FocusState private var focus: GithubAccountField?
    @EnvironmentObject private var store: Store

    init(row: JSON?) {
        self.row = row
        _model = StateObject(wrappedValue: GithubAccountFormModel(row: row))
    }

    private var state: GithubAccountFormState { model.state }

    var body: some View {
        SettingsPage(header: header,
                     unavailable: settingsUnavailable("settings_github_accounts", path: "settings/github/accounts", what: "GitHub accounts", manage: "them"),
                     scrollToken: model.scrollToken) {
            SettingsTabs(tabs: [SettingsTabs.Tab(id: 0, title: "GitHub account", glyph: Glyph.symbol(0xE77B), dot: model.tabDot)], open: 0) { _ in }
            if let error = model.error { NoticeBox(message: error).padding(.bottom, 16) }
            SettingsPair { field(.label) } right: { field(.token) }
            GithubAccountFactsBox(facts: GithubAccountFormState.facts(state.row))
            projects
        }
        .onAppear {
            if let f = model.focusFirst {
                model.focusFirst = nil
                DispatchQueue.main.async { focus = f }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveScreen)) { _ in model.save() }
    }

    /// The projects the account serves, one tick box each; one another account serves says which, as the server refuses
    /// to give a project two.
    @ViewBuilder private var projects: some View {
        let listed = settings.projects.list.compactMap { $0["repo"].nonEmpty }
        let choices = settingsRepoChoices(projects: listed, ticked: state.repos)
        VStack(alignment: .leading, spacing: 0) {
            SettingsFieldLabel(label: "Projects", hint: "The server reads and writes GitHub for these projects with this account. A project is served by one account at most; the others use the server's own token.")
            ForEach(choices, id: \.self) { repo in
                let on = state.repos.contains(repo)
                let taken = on ? nil : state.takenBy(repo, accounts: accounts.section.list)
                let gone = !listed.contains(repo)
                SettingsCheck(label: gone ? "\(repo) (not a project)" : taken.map { "\(repo) · served by \($0)" } ?? repo,
                              on: on, height: 28, muted: gone || taken != nil) { model.toggle(repo) }
            }
            if choices.isEmpty { SettingsHint(text: "No projects yet. Add one under Projects first.") }
        }
        .padding(.bottom, 14)
    }

    private var header: PaneHeader {
        let id = state.id
        var buttons: [HeaderButton] = []
        if store.supports("settings_github_accounts") {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74E), label: model.saving ? "Saving…" : "Save", tip: "Save this GitHub account (⌘S)",
                                        enabled: !model.busy && (state.dirty || id == 0) && store.supports(state.saveOperation),
                                        prominent: true) { model.save() })
            if id != 0 {
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74D), tip: "Delete this GitHub account",
                                            enabled: !model.busy && store.supports("delete_github_account"), destructive: true) { model.delete() })
            }
        }
        return id != 0
            ? PaneHeader(title: state.row["label"].nonEmpty ?? state.row["login"].nonEmpty ?? "GitHub account",
                         subtitle: GithubAccountFormState.subtitle(state.row), buttons: buttons)
            : PaneHeader(title: "New GitHub account", subtitle: "A GitHub token the server uses for the projects you tick.", buttons: buttons)
    }

    private func field(_ f: GithubAccountField) -> some View {
        var def = f.def
        // The token's box says whether one is stored.
        if f == .token { def.cue = state.tokenCue }
        return SettingsFieldBox(def: def, text: model.binding(f), focus: $focus, key: f) {
            let all = GithubAccountField.allCases
            focus = all[((all.firstIndex(of: f) ?? 0) + 1) % all.count]
        }
    }
}

/// What GitHub said about the stored token, read-only: its login, user id and scopes. Nothing for an account not saved yet.
private struct GithubAccountFactsBox: View {
    var facts: [GithubAccountFact]
    var body: some View {
        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SettingsFieldLabel(label: "Verified with GitHub", hint: "Read again from GitHub each time the token changes.")
                ForEach(facts, id: \.label) { SettingsStatusRow(label: $0.label, value: $0.value, mono: $0.mono) }
            }
            .padding(.bottom, 14)
        }
    }
}
