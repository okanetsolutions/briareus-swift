// A Laravel Forge account, as the Mac's form on a phone: label and organization, the write-only API token (its box says
// whether one is stored), and the projects the account is available to, one tick each. Saved through
// /settings/forge/accounts, which needs an Admin token.
import SwiftUI

@MainActor
private final class ForgeAccountFormModel: ObservableObject {
    @Published var state: ForgeAccountFormState
    @Published var saving = false
    @Published var deleting = false
    @Published var error: String?
    @Published var scrollToken = 0
    var focusFirst: ForgeAccountField?

    init(row: JSON?, defaults: JSON?) {
        let r: JSON = row?.isObject == true ? row! : defaults?.isObject == true ? defaults! : [:]
        state = ForgeAccountFormState(row: r)
        // A new account starts where its organization is typed, the one box it cannot do without.
        if state.id == 0 { focusFirst = .organization }
    }

    var busy: Bool { saving || deleting }

    func binding(_ f: ForgeAccountField) -> Binding<String> {
        Binding(get: { self.state.text(f) }, set: { v in
            let value = String(v.prefix(f.limit))
            guard value != self.state.text(f) else { return }
            self.state.texts[f] = value
            self.changed()
        })
    }
    func ticked(_ repo: String) -> Binding<Bool> {
        Binding(get: { self.state.repos.contains(repo) }, set: { on in
            guard on != self.state.repos.contains(repo) else { return }
            self.state.toggle(repo)
            self.changed()
        })
    }

    private func changed() { if !state.dirty { state.dirty = true } }
    var discardMessage: String {
        state.id != 0 ? "The changes to \(state.row["label"].nonEmpty ?? "this Forge account") have not been saved." : "The new Forge account has not been saved."
    }
    private func showError(_ text: String?) {
        guard let text else { return }
        error = text; scrollToken += 1
    }

    func save(done: @escaping () -> Void) {
        let id = state.id
        guard !busy, Store.shared.supports(id != 0 ? "update_forge_account" : "create_forge_account") else { return }
        var body: JSON
        switch state.body() {
        case .failure(let p): showError(p.message); return
        case .success(let b): body = b
        }
        if id != 0 { body["id"] = .number(id) }
        saving = true
        Task {
            defer { saving = false }
            do {
                let r = try await Store.shared.call(id != 0 ? "update_forge_account" : "create_forge_account", body)
                let row = r["account"]
                guard row.isObject else { showError(settingsUnexpectedResponse); return }
                // The server's word on what was saved: an empty label is now the organization, and a new account has an id.
                error = nil
                state.row = row
                state.fill()
                Task { try? await SettingsLists.shared.loadForge() }
                done()
            } catch {
                showError(failure(error))
            }
        }
    }

    func delete(done: @escaping () -> Void) {
        guard state.id != 0, !busy else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                try await Store.shared.call("delete_forge_account", ["id": .number(state.id)])
                state.dirty = false
                Task { try? await SettingsLists.shared.loadForge() }
                done()
            } catch {
                showError(failure(error))
            }
        }
    }
}

struct ForgeAccountSettingsScreen: View {
    let row: JSON?
    let defaults: JSON?
    @StateObject private var model: ForgeAccountFormModel
    @ObservedObject private var lists = SettingsLists.shared
    @FocusState private var focus: ForgeAccountField?
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: ForgeAccountFormModel(row: row, defaults: defaults))
    }

    private var state: ForgeAccountFormState { model.state }

    var body: some View {
        if let why = settingsUnavailableReason("settings_forge_accounts", path: "settings/forge/accounts", what: "Forge accounts", manage: "them") {
            SettingsUnavailableView(text: why).navigationTitle("Forge account")
        } else {
            form
        }
    }

    private var form: some View {
        let id = state.id
        return ScrollViewReader { proxy in
            Form {
                Section { EmptyView() } footer: {
                    Text(id != 0 ? ForgeAccountFormState.subtitle(state.row) : "A Laravel Forge organization, and the projects whose clients may use it.")
                }
                SettingsErrorSection(error: model.error)
                Section {
                    field(.label)
                    field(.organization)
                    field(.token)
                }
                .listRowBackground(Theme.row)
                projects
            }
            .onChange(of: model.scrollToken) { _, _ in withAnimation { proxy.scrollTo(settingsErrorID, anchor: .top) } }
        }
        .modifier(SettingsFormChrome(
            title: id != 0 ? state.row["label"].nonEmpty ?? state.row["organization"].nonEmpty ?? "Forge account" : "New Forge account",
            dirty: state.dirty, discardMessage: model.discardMessage, saveTitle: "Save",
            canSave: !model.busy && (state.dirty || id == 0) && store.supports(id != 0 ? "update_forge_account" : "create_forge_account"),
            saving: model.saving, onSave: { focus = nil; model.save { dismiss() } },
            deleteTitle: "Delete Forge account",
            onDelete: id != 0 && store.supports("delete_forge_account") ? { confirmDelete = true } : nil))
        .alert("Delete \(state.row["label"].nonEmpty ?? "this Forge account")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete { dismiss() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its stored token is removed and clients can no longer reach the organization's Forge servers and sites through it.")
        }
        .onAppear {
            if let f = model.focusFirst {
                model.focusFirst = nil
                DispatchQueue.main.async { focus = f }
            }
        }
    }

    /// The projects the account is available to, one switch each; a ticked one that is no longer a project stays listed
    /// so it can be unticked.
    @ViewBuilder private var projects: some View {
        let listed = lists.projects.list.compactMap { $0["repo"].nonEmpty }
        let choices = settingsRepoChoices(projects: listed, ticked: state.repos)
        Section {
            ForEach(choices, id: \.self) { repo in
                let gone = !listed.contains(repo)
                Toggle(isOn: model.ticked(repo)) {
                    Text(gone ? "\(repo) (not a project)" : repo).foregroundStyle(gone ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                }
                .tint(Theme.accent)
            }
            if choices.isEmpty { Text("No projects yet. Add one under Projects first.").foregroundStyle(.secondary) }
        } header: {
            Text("Projects")
        } footer: {
            Text("Only these projects offer the account's Forge servers and sites to their clients.")
        }
        .listRowBackground(Theme.row)
    }

    private func field(_ f: ForgeAccountField) -> some View {
        var def = f.def
        // The token's box says whether one is stored.
        if f == .token { def.cue = state.tokenCue }
        return SettingsTextRow(def: def, text: model.binding(f), focus: $focus, key: f)
    }
}
