// An SSH server a project's agents may run commands on, as the Mac's form on a phone. The Server tab: label, project,
// host and port, username and private key path, the SSH and sudo passwords on a server that takes them (write-only: the
// server only says whether one is stored), the permission mode and whether sessions may use it. The Database tab,
// on a server that stores one: where the database listens as seen from the server, and the login for it, which the
// server keeps encrypted and opens only through GET …/db-credentials, read here when the tab first shows; a save sends
// only the half of the login that changed. Saved through /settings/ssh/servers, which needs an Admin token.
import SwiftUI

struct SSHServerSettingsScreen: View {
    let row: JSON?
    let defaults: JSON?
    @StateObject private var model: SSHServerFormModel
    @ObservedObject private var lists = SettingsLists.shared
    @FocusState private var focus: SSHServerField?
    @EnvironmentObject private var store: Store
    @Environment(\.navigate) private var navigate
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: SSHServerFormModel(row: row, defaults: defaults))
    }

    private var state: SSHServerFormState { model.state }

    var body: some View {
        if let why = settingsUnavailableReason("settings_ssh_servers", path: "settings/ssh/servers", what: "SSH servers", manage: "them") {
            SettingsUnavailableView(text: why).navigationTitle("SSH server")
        } else {
            form
        }
    }

    private var form: some View {
        let id = state.id
        return ScrollViewReader { proxy in
            Form {
                // The Database tab only on a server that stores a database login with an SSH server.
                if state.offersDatabase {
                    Section {
                        Picker("Section", selection: Binding(get: { model.tab }, set: { focus = nil; model.tab = $0 })) {
                            ForEach(SSHServerTab.allCases, id: \.self) { t in Text(settingsTabTitle(t.title, changed: model.tabDot(t))).tag(t) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    } footer: { subtitle }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } else {
                    Section { EmptyView() } footer: { subtitle }
                }
                SettingsErrorSection(error: model.error)
                switch state.offersDatabase ? model.tab : .server {
                case .server: serverTab
                case .database: databaseTab
                }
            }
            .onChange(of: model.scrollToken) { _, _ in withAnimation { proxy.scrollTo(settingsErrorID, anchor: .top) } }
        }
        .modifier(SettingsFormChrome(
            title: id != 0 ? state.row["label"].nonEmpty ?? state.row["host"].nonEmpty ?? "SSH server" : "New SSH server",
            dirty: state.dirty, discardMessage: model.discardMessage, saveTitle: "Save",
            canSave: !model.busy && (state.dirty || id == 0) && store.supports(state.saveOperation),
            saving: model.saving, onSave: { focus = nil; model.save { dismiss() } },
            cloneTitle: "Clone into a new SSH server",
            onClone: id != 0 && store.supports("create_ssh_server") ? { if let copy = model.cloneRow() { navigate(.sshServerSettings(row: copy, defaults: nil)) } } : nil,
            deleteTitle: "Delete SSH server",
            onDelete: id != 0 && store.supports("delete_ssh_server") ? { confirmDelete = true } : nil))
        .alert("Delete \(state.row["label"].nonEmpty ?? "this SSH server")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete { dismiss() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions lose access through the SSH tool and pending approvals are cancelled.")
        }
        .onAppear {
            if let f = model.focusFirst {
                model.focusFirst = nil
                DispatchQueue.main.async { focus = f }
            }
        }
    }

    private var subtitle: Text {
        Text(state.id != 0 ? SSHServerFormState.subtitle(state.row) : "A server a project's agents may run commands on, with approval.")
    }

    // MARK: SSH server

    @ViewBuilder private var serverTab: some View {
        let repos = lists.projects.list.compactMap { $0["repo"].string }
        Section {
            field(.label)
            // A project that is gone stays picked rather than being swapped for another; the server refuses it on save.
            Picker(selection: model.repoBinding) {
                if state.repo.isEmpty { Text("Choose a project").tag("") }
                ForEach(repos, id: \.self) { Text($0).tag($0) }
                if !state.repo.isEmpty && !repos.contains(state.repo) { Text("\(state.repo) (not a project)").tag(state.repo) }
            } label: {
                SettingsLabel(label: "Project", hint: "Only this project's sessions see the server, through their SSH tool.")
            }
        }
        .listRowBackground(Theme.row)
        Section {
            field(.host)
            field(.port)
            field(.username)
            field(.key)
        } header: {
            Text("Connection")
        }
        .listRowBackground(Theme.row)
        // Each password only on a server that takes it; it keeps them sealed and only says whether one is stored.
        if state.offersPasswords {
            Section {
                if state.offers(.password) { secret(.password) }
                if state.offers(.sudoPassword) { secret(.sudoPassword) }
            } header: {
                Text("Passwords")
            }
            .listRowBackground(Theme.row)
        }
        Section {
            Picker(selection: model.modeBinding) {
                ForEach(["ask", "allow"], id: \.self) { Text(SSHServerFormState.modeTitle($0)).tag($0) }
            } label: {
                SettingsLabel(label: "Permission mode",
                              hint: "Ask holds each command until it is approved. Don't ask anything sends every command immediately.")
            }
            Toggle("Available to sessions on this project", isOn: model.enabledBinding).tint(Theme.accent)
        } footer: {
            Text("First verify the server's host key and add it to the Briareus account's known_hosts file. Unknown or changed host keys are refused. SSH configuration aliases and interactive commands are not supported.")
        }
        .listRowBackground(Theme.row)
    }

    // MARK: Database

    /// Where the server's database listens and the login for it, for a client that tunnels to it over this server.
    @ViewBuilder private var databaseTab: some View {
        Section {
            field(.dbHost)
            field(.dbPort)
        } footer: {
            Text("The database on this server, reached through an SSH tunnel over it. The login is stored encrypted on Briareus, never shown to agents, and read back only with an Admin token.")
        }
        .listRowBackground(Theme.row)
        Section {
            if model.readingLogin {
                HStack(spacing: 10) { ProgressView(); Text("Reading the stored login…").foregroundStyle(.secondary) }
            } else if let error = model.loginError {
                ErrorNotice(message: "The stored login could not be read: \(error)")
            }
            field(.dbUsername, hint: loginHint(.dbUsername))
            field(.dbPassword, hint: loginHint(.dbPassword))
        } header: {
            Text("Login")
        }
        .listRowBackground(Theme.row)
    }

    /// What the login's info buttons say once one is stored: how to replace it while it is not read, how to remove it
    /// once it is. Without one, the fields' own hints.
    private func loginHint(_ f: SSHServerField) -> String? {
        guard state.hasLogin else { return nil }
        if !state.loginKnown {
            return f == .dbUsername ? "A login is stored. Type a username to replace it; the stored password stays as it is."
                                    : "A password is stored. Type one to replace it; leave empty to keep it."
        }
        return f == .dbUsername ? "Empty it to remove the stored login, password and all." : nil
    }

    /// A write-only password: empty, it says whether one is stored; a switch under it removes the stored one on save.
    private func secret(_ f: SSHServerField) -> some View {
        var def = f.def
        def.cue = state.cue(f)
        return Group {
            SettingsTextRow(def: def, text: model.binding(f), focus: $focus, key: f)
            if state.stored(f) {
                Toggle("Remove the stored \(f.def.label.lowercased()) on save",
                       isOn: Binding(get: { state.clear.contains(f) }, set: { _ in model.toggleClear(f) }))
                    .tint(Theme.accent)
            }
        }
    }

    private func field(_ f: SSHServerField, hint: String? = nil) -> some View {
        SettingsTextRow(def: f.def, text: model.binding(f), hint: hint, focus: $focus, key: f)
    }
}
