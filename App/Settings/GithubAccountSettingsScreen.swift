// A GitHub account, as the Mac's form on a phone: its label and write-only token (its box says whether one is stored),
// what GitHub said about the stored token (login, user id, classic scopes; a fine-grained token reports none), and the
// projects it serves, one switch each, a project another account serves marked. Saved through
// /settings/github/accounts, which needs an Admin token. The token typed goes only in the save's body.
import SwiftUI

@MainActor
private final class GithubAccountFormModel: ObservableObject {
    @Published var state: GithubAccountFormState
    @Published var saving = false
    @Published var deleting = false
    @Published var error: String?
    @Published var scrollToken = 0
    var focusFirst: GithubAccountField?

    init(row: JSON?) {
        state = GithubAccountFormState(row: row?.isObject == true ? row! : [:])
        // A new account starts where its token is pasted, the one box it cannot do without.
        if state.id == 0 { focusFirst = .token }
    }

    var busy: Bool { saving || deleting }

    func binding(_ f: GithubAccountField) -> Binding<String> {
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
    private func showError(_ text: String?) {
        guard let text else { return }
        error = text; scrollToken += 1
    }
    /// A refusal as the form tells it: a project another account serves in words that say what to do, else the server's;
    /// nil for a save only abandoned.
    private func refusal(_ error: Error) -> String? {
        guard let text = failure(error) else { return nil }
        return (error as? APIError).flatMap(GithubAccountFormState.saveProblem) ?? text
    }

    func save(done: @escaping () -> Void) {
        guard !busy, Store.shared.supports(state.saveOperation) else { return }
        let body: JSON
        switch state.saveRequest() {
        case .failure(let p): showError(p.message); return
        case .success(let b): body = b
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                let r = try await Store.shared.call(state.saveOperation, body)
                // The server's word on what was saved: the login GitHub verified, an empty label now that login, and a new
                // account's id. Filling the form again empties the token's box.
                guard state.saved(r) != nil else { showError(settingsUnexpectedResponse); return }
                error = nil
                Task { try? await SettingsLists.shared.loadGithub() }
                done()
            } catch {
                showError(refusal(error))
            }
        }
    }

    func delete(done: @escaping () -> Void) {
        guard state.id != 0, !busy else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                try await Store.shared.call("delete_github_account", ["id": .number(state.id)])
                state.dirty = false
                Task { try? await SettingsLists.shared.loadGithub() }
                done()
            } catch {
                showError(refusal(error))
            }
        }
    }
}

struct GithubAccountSettingsScreen: View {
    let row: JSON?
    @StateObject private var model: GithubAccountFormModel
    @ObservedObject private var lists = SettingsLists.shared
    @FocusState private var focus: GithubAccountField?
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    init(row: JSON?) {
        self.row = row
        _model = StateObject(wrappedValue: GithubAccountFormModel(row: row))
    }

    private var state: GithubAccountFormState { model.state }

    var body: some View {
        if let why = settingsUnavailableReason("settings_github_accounts", path: "settings/github/accounts", what: "GitHub accounts", manage: "them") {
            SettingsUnavailableView(text: why).navigationTitle("GitHub account")
        } else {
            form
        }
    }

    private var form: some View {
        let id = state.id
        return ScrollViewReader { proxy in
            Form {
                Section { EmptyView() } footer: {
                    Text(id != 0 ? GithubAccountFormState.subtitle(state.row) : "A GitHub token the server uses for the projects you tick.")
                }
                SettingsErrorSection(error: model.error)
                Section {
                    field(.label)
                    field(.token)
                }
                .listRowBackground(Theme.row)
                GithubAccountFactsSection(facts: GithubAccountFormState.facts(state.row))
                projects
            }
            .onChange(of: model.scrollToken) { _, _ in withAnimation { proxy.scrollTo(settingsErrorID, anchor: .top) } }
        }
        .modifier(SettingsFormChrome(
            title: id != 0 ? GithubAccountFormState.title(state.row) : "New GitHub account",
            dirty: state.dirty, discardMessage: state.discardMessage, saveTitle: "Save",
            canSave: !model.busy && (state.dirty || id == 0) && store.supports(state.saveOperation),
            saving: model.saving, onSave: { focus = nil; model.save { dismiss() } },
            deleteTitle: "Delete GitHub account",
            onDelete: id != 0 && store.supports("delete_github_account") ? { confirmDelete = true } : nil))
        .alert("Delete \(state.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete { dismiss() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its stored token is removed, and its projects read and write GitHub without it.")
        }
        .onAppear {
            if let f = model.focusFirst {
                model.focusFirst = nil
                DispatchQueue.main.async { focus = f }
            }
        }
    }

    /// The projects the account serves, one switch each; a ticked one that is no longer a project stays listed so it can be
    /// unticked, and one another account serves says which.
    @ViewBuilder private var projects: some View {
        let listed = lists.projects.list.compactMap { $0["repo"].nonEmpty }
        let choices = settingsRepoChoices(projects: listed, ticked: state.repos)
        Section {
            ForEach(choices, id: \.self) { repo in
                let gone = !listed.contains(repo)
                let taken = state.repos.contains(repo) ? nil : state.takenBy(repo, accounts: lists.github.list)
                Toggle(isOn: model.ticked(repo)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gone ? "\(repo) (not a project)" : repo).foregroundStyle(gone ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                        if let taken { Text("Served by \(taken)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                .tint(Theme.accent)
            }
            if choices.isEmpty { Text("No projects yet. Add one under Projects first.").foregroundStyle(.secondary) }
        } header: {
            Text("Projects")
        } footer: {
            Text("The server reads and writes GitHub for these projects with this account. A project is served by one account at most; the others use the server's own token.")
        }
        .listRowBackground(Theme.row)
    }

    private func field(_ f: GithubAccountField) -> some View {
        var def = f.def
        // The token's box says whether one is stored.
        if f == .token { def.cue = state.tokenCue }
        return SettingsTextRow(def: def, text: model.binding(f), focus: $focus, key: f)
    }
}

/// What GitHub said about the stored token, read-only: its login, user id and scopes. Nothing for an account not saved yet.
private struct GithubAccountFactsSection: View {
    var facts: [GithubAccountFact]
    var body: some View {
        if !facts.isEmpty {
            Section {
                ForEach(facts, id: \.label) { SettingsValueRow(label: $0.label, value: $0.value, mono: $0.mono) }
            } header: {
                Text("Verified with GitHub")
            } footer: {
                Text("Read again from GitHub each time the token changes.")
            }
            .listRowBackground(Theme.row)
        }
    }
}
