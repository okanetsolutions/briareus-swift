// An SSH server a project's agents may run commands on, as the web's form has it, across the whole pane with its fields
// two to a row. The SSH server tab: Label and Project, Host and Port, Username and Private key path, the SSH and sudo
// passwords on a server that takes them (write-only: the server only says whether one is stored), and the Permission
// mode beside "Available to sessions on this project". The Database tab, on a server that stores one: where the database
// listens as seen from the server, and the login for it, which the server keeps encrypted and opens only through
// GET …/db-credentials, read here when the tab is first shown. Saved through /settings/ssh/servers, which needs an Admin
// token.
import SwiftUI

struct SSHServerSettingsScreen: View {
    var row: JSON?
    var defaults: JSON?
    @StateObject private var model: SSHServerFormModel
    @FocusState private var focus: SSHServerField?
    @EnvironmentObject private var store: Store

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: SSHServerFormModel(row: row, defaults: defaults))
    }

    private var state: SSHServerFormState { model.state }

    var body: some View {
        SettingsPage(header: header,
                     unavailable: settingsUnavailable("settings_ssh_servers", path: "settings/ssh/servers", what: "SSH servers", manage: "them"),
                     scrollToken: model.scrollToken) {
            // The Database tab only on a server that stores a database login with an SSH server.
            let tabs = state.offersDatabase ? SSHServerTab.allCases : [.server]
            SettingsTabs(tabs: tabs.map { t in
                SettingsTabs.Tab(id: t.rawValue, title: t.title, glyph: Glyph.symbol(t == .server ? 0xE968 : 0xE1D3), dot: model.tabDot(t))
            }, open: model.tab.rawValue) { t in
                focus = nil
                model.tab = SSHServerTab(rawValue: t) ?? .server
                model.scrollToken += 1
            }
            if let error = model.error { NoticeBox(message: error).padding(.bottom, 16) }
            switch model.tab {
            case .server: serverTab
            case .database: databaseTab
            }
        }
        .onAppear {
            if let f = model.focusFirst {
                model.focusFirst = nil
                DispatchQueue.main.async { focus = f }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveScreen)) { _ in model.save() }
    }

    // MARK: SSH server

    @ViewBuilder private var serverTab: some View {
        SettingsPair {
            field(.label)
        } right: {
            SettingsLabeledSelect(label: "Project", text: state.repo.isEmpty ? "Choose a project" : state.repo,
                                  hint: "Only this project's sessions see the server, through their SSH tool.") { model.pickRepo() }
        }
        SettingsPair { field(.host) } right: { field(.port) }
        SettingsPair { field(.username) } right: { field(.key) }
        // Each password only on a server that takes it; it keeps them sealed and only says whether one is stored.
        if state.offersPasswords {
            SettingsPair {
                if state.offers(.password) { secret(.password) }
            } right: {
                if state.offers(.sudoPassword) { secret(.sudoPassword) }
            }
        }
        SettingsPair {
            SettingsLabeledSelect(label: "Permission mode", text: SSHServerFormState.modeTitle(state.mode),
                                  hint: "Ask holds each command until it is approved. Don't ask anything sends every command immediately.") { model.pickMode() }
        } right: {
            // Level with the box beside it: below where its label sits, centred on its height.
            SettingsCheck(label: "Available to sessions on this project", on: state.enabled, height: 36) { model.toggle() }
                .padding(.top, SettingsFonts.footnoteLineHeight + 6).padding(.bottom, 14)
        }
        SettingsNote(text: "First verify the server's host key and add it to the Briareus account's known_hosts file. Unknown or changed host keys are refused. SSH configuration aliases and interactive commands are not supported.")
    }

    // MARK: Database

    /// Where the server's database listens and the login for it, for a client that tunnels to it over this server.
    @ViewBuilder private var databaseTab: some View {
        SettingsNote(text: "The database on this server, reached through an SSH tunnel over it. The login is stored encrypted on Briareus, never shown to agents, and read back only with an Admin token.")
        Color.clear.frame(height: 8)
        HStack(alignment: .top, spacing: 14) {
            field(.dbHost).frame(maxWidth: .infinity)
            field(.dbPort).frame(width: 140)
        }
        if model.readingLogin {
            SettingsNote(text: "Reading the stored login…")
        } else if let error = model.loginError {
            NoticeBox(message: "The stored login could not be read: \(error)").padding(.bottom, 16)
        }
        SettingsPair { field(.dbUsername, hint: loginHint(.dbUsername)) } right: { field(.dbPassword, hint: loginHint(.dbPassword)) }
    }

    /// What the login's help icons say once one is stored: how to replace it while it is not read, how to remove it once
    /// it is. Without one, the fields' own hints.
    private func loginHint(_ f: SSHServerField) -> String? {
        guard state.hasLogin else { return nil }
        if !state.loginKnown {
            return f == .dbUsername ? "A login is stored. Type a username to replace it; the stored password stays as it is."
                                    : "A password is stored. Type one to replace it; leave empty to keep it."
        }
        return f == .dbUsername ? "Empty it to remove the stored login, password and all." : nil
    }

    private var header: PaneHeader {
        let id = state.id
        var buttons: [HeaderButton] = []
        if store.supports("settings_ssh_servers") {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74E), label: model.saving ? "Saving…" : "Save", tip: "Save this SSH server (⌘S)",
                                        enabled: !model.busy && (state.dirty || id == 0) && store.supports(state.saveOperation),
                                        prominent: true) { model.save() })
            if id != 0 {
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE8C8), tip: "Clone into a new SSH server",
                                            enabled: !model.busy && store.supports("create_ssh_server")) { model.clone() })
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74D), tip: "Delete this SSH server",
                                            enabled: !model.busy && store.supports("delete_ssh_server"), destructive: true) { model.delete() })
            }
        }
        return id != 0
            ? PaneHeader(title: state.row["label"].nonEmpty ?? state.row["host"].nonEmpty ?? "SSH server", subtitle: SSHServerFormState.subtitle(state.row), buttons: buttons)
            : PaneHeader(title: "New SSH server", subtitle: "A server a project's agents may run commands on, with approval.", buttons: buttons)
    }

    /// A write-only password: empty, it says whether one is stored; a check under it removes the stored one on save.
    private func secret(_ f: SSHServerField) -> some View {
        var def = f.def
        def.cue = state.cue(f)
        return SettingsSecretBox(def: def, text: model.binding(f), focus: $focus, key: f, stored: state.stored(f), removing: state.clear.contains(f),
                                 removeLabel: "Remove the stored \(f.def.label.lowercased()) on save", onToggleRemove: { model.toggleClear(f) }) {
            focusNext(after: f)
        }
    }

    private func field(_ f: SSHServerField, hint: String? = nil) -> some View {
        SettingsFieldBox(def: f.def, text: model.binding(f), hint: hint, focus: $focus, key: f) { focusNext(after: f) }
    }
    /// Tab moves to the next box the tab shows, round to the first.
    private func focusNext(after f: SSHServerField) {
        let all = state.fields(on: f.tab)
        focus = all[((all.firstIndex(of: f) ?? 0) + 1) % all.count]
    }
}
