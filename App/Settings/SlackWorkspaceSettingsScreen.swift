// A Slack workspace, as the Mac's form on a phone: who it sends as, once a token is stored; the label, the write-only
// User OAuth token and signing secret (their boxes say whether one is stored), with the scopes the token needs; the
// Request URL for the Slack app's Event Subscriptions, with Copy; and the projects that may send through it, each ticked
// one with its channels, whether it may write to people and whether each message waits for approval. A project another
// workspace already serves is marked. Saved through /settings/slack/workspaces, which needs an Admin token.
import SwiftUI

/// A box of the form: one of its fields, or a ticked project's channels.
private enum SlackFormFocus: Hashable {
    case field(SlackWorkspaceField)
    case channels(String)
}

@MainActor
private final class SlackWorkspaceFormModel: ObservableObject {
    @Published var state: SlackWorkspaceFormState
    @Published var saving = false
    @Published var deleting = false
    @Published var error: String?
    @Published var scrollToken = 0
    var focusFirst: SlackFormFocus?

    init(row: JSON?, defaults: JSON?) {
        let r: JSON = row?.isObject == true ? row! : defaults?.isObject == true ? defaults! : [:]
        state = SlackWorkspaceFormState(row: r)
        // A new workspace starts where its token is pasted, the one box it cannot do without.
        if state.id == 0 { focusFirst = .field(.token) }
    }

    var busy: Bool { saving || deleting }

    func binding(_ f: SlackWorkspaceField) -> Binding<String> {
        Binding(get: { self.state.text(f) }, set: { v in
            let value = String(v.prefix(f.limit))
            guard value != self.state.text(f) else { return }
            self.state.texts[f] = value
            self.changed()
        })
    }
    func ticked(_ repo: String) -> Binding<Bool> {
        Binding(get: { self.state.rule(repo) != nil }, set: { on in
            guard on != (self.state.rule(repo) != nil) else { return }
            self.state.toggle(repo)
            self.changed()
        })
    }
    /// One part of a ticked project's rule.
    private func rule<T: Equatable>(_ repo: String, _ key: WritableKeyPath<SlackProjectRule, T>, empty: T) -> Binding<T> {
        Binding(get: { self.state.rule(repo)?[keyPath: key] ?? empty }, set: { v in
            guard let i = self.state.projects.firstIndex(where: { $0.repo == repo }), self.state.projects[i][keyPath: key] != v else { return }
            self.state.projects[i][keyPath: key] = v
            self.changed()
        })
    }
    func channels(_ repo: String) -> Binding<String> {
        let b = rule(repo, \.channels, empty: "")
        return Binding(get: { b.wrappedValue }, set: { b.wrappedValue = String($0.prefix(2000)) })
    }
    func directMessages(_ repo: String) -> Binding<Bool> { rule(repo, \.directMessages, empty: true) }
    func allow(_ repo: String) -> Binding<Bool> { rule(repo, \.allow, empty: false) }

    private func changed() { if !state.dirty { state.dirty = true } }
    var discardMessage: String {
        state.id != 0 ? "The changes to \(state.row["label"].nonEmpty ?? "this Slack workspace") have not been saved." : "The new Slack workspace has not been saved."
    }
    private func showError(_ text: String?) {
        guard let text else { return }
        error = text; scrollToken += 1
    }

    func save(done: @escaping () -> Void) {
        let id = state.id
        guard !busy, Store.shared.supports(id != 0 ? "update_slack_workspace" : "create_slack_workspace") else { return }
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
                let r = try await Store.shared.call(id != 0 ? "update_slack_workspace" : "create_slack_workspace", body)
                let row = r["workspace"]
                guard row.isObject else { showError(settingsUnexpectedResponse); return }
                // The server's word on what was saved: who the token is, an empty label now the workspace's name, and a new
                // workspace's id and Request URL.
                error = nil
                state.row = row
                state.fill()
                Task { try? await SettingsLists.shared.loadSlack() }
                // A new workspace stays open, so its Request URL can be copied into the Slack app.
                if id != 0 { done() }
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
                try await Store.shared.call("delete_slack_workspace", ["id": .number(state.id)])
                state.dirty = false
                Task { try? await SettingsLists.shared.loadSlack() }
                done()
            } catch {
                showError(failure(error))
            }
        }
    }
}

struct SlackWorkspaceSettingsScreen: View {
    let row: JSON?
    let defaults: JSON?
    @StateObject private var model: SlackWorkspaceFormModel
    /// The projects, and the other workspaces whose projects this form marks as taken.
    @ObservedObject private var lists = SettingsLists.shared
    @FocusState private var focus: SlackFormFocus?
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var copied = false

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: SlackWorkspaceFormModel(row: row, defaults: defaults))
    }

    private var state: SlackWorkspaceFormState { model.state }

    var body: some View {
        if let why = settingsUnavailableReason("settings_slack_workspaces", path: "settings/slack/workspaces", what: "Slack workspaces", manage: "them") {
            SettingsUnavailableView(text: why).navigationTitle("Slack workspace")
        } else {
            form
        }
    }

    private var form: some View {
        let id = state.id
        return ScrollViewReader { proxy in
            Form {
                Section { EmptyView() } footer: {
                    Text(id != 0 ? SlackWorkspaceFormState.subtitle(state.row) : "Sessions send Slack messages as you, and hear the replies.")
                }
                SettingsErrorSection(error: model.error)
                if id != 0 && state.hasToken { connection }
                Section {
                    field(.label)
                    field(.token)
                } footer: {
                    Text("Create a Slack app at api.slack.com/apps and give it these user token scopes under OAuth & Permissions: \(SlackWorkspaceFormState.scopes). Install it to the workspace, then paste its User OAuth Token.")
                }
                .listRowBackground(Theme.row)
                Section { field(.signingSecret) }.listRowBackground(Theme.row)
                events
                projects
            }
            .onChange(of: model.scrollToken) { _, _ in withAnimation { proxy.scrollTo(settingsErrorID, anchor: .top) } }
        }
        .modifier(SettingsFormChrome(
            title: id != 0 ? state.row["label"].nonEmpty ?? state.row["team"].nonEmpty ?? "Slack workspace" : "New Slack workspace",
            dirty: state.dirty, discardMessage: model.discardMessage, saveTitle: "Save",
            canSave: !model.busy && (state.dirty || id == 0) && store.supports(id != 0 ? "update_slack_workspace" : "create_slack_workspace"),
            saving: model.saving, onSave: { focus = nil; model.save { dismiss() } },
            deleteTitle: "Delete Slack workspace",
            onDelete: id != 0 && store.supports("delete_slack_workspace") ? { confirmDelete = true } : nil))
        .alert("Delete \(state.row["label"].nonEmpty ?? "this Slack workspace")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete { dismiss() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its stored token and signing secret are removed: its projects' sessions can no longer send Slack messages, and replies stop reaching them.")
        }
        .onAppear {
            if let f = model.focusFirst {
                model.focusFirst = nil
                DispatchQueue.main.async { focus = f }
            }
        }
    }

    /// Who the workspace's messages go out as, from Slack, once a token is stored.
    private var connection: some View {
        Section("Connection") {
            SettingsValueRow(label: "Workspace", value: state.row["team"].nonEmpty ?? "—")
            if let url = state.row["url"].nonEmpty { SettingsValueRow(label: "Address", value: url) }
            SettingsValueRow(label: "Sends as", value: state.row["user"].nonEmpty ?? "—")
        }
        .listRowBackground(Theme.row)
    }

    /// Where Slack sends the replies: the Request URL for the app's Event Subscriptions, with Copy.
    private var events: some View {
        Section {
            if state.id == 0 {
                Text("Save the workspace to get the Request URL its replies come back through.").foregroundStyle(.secondary)
            } else if let url = state.row["eventsUrl"].nonEmpty {
                Text(url).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                Button {
                    Pasteboard.copy(url)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Request URL", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            } else {
                Text("The server has no public address (PUBLIC_BASE_URL), so it has no Request URL to give Slack: messages can be sent, but replies do not reach the sessions.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Request URL")
        } footer: {
            if state.id != 0 && state.row["eventsUrl"].nonEmpty != nil {
                Text("Turn on the Slack app's Event Subscriptions with this as the Request URL, and subscribe on behalf of users to message.im, message.channels and message.groups. Like the server's other webhooks, the path must bypass Cloudflare Access."
                     + (state.hasSigningSecret ? "" : " Replies reach the sessions once the signing secret is saved."))
            }
        }
        .listRowBackground(Theme.row)
    }

    /// The projects that may send through the workspace, one switch each; a ticked one opens its channels, whether it may
    /// write to people and whether each message waits for approval.
    @ViewBuilder private var projects: some View {
        let listed = lists.projects.list.compactMap { $0["repo"].nonEmpty }
        let choices = settingsRepoChoices(projects: listed, ticked: state.projects.map(\.repo))
        Section {
            ForEach(choices, id: \.self) { repo in
                let rule = state.rule(repo)
                let taken = rule == nil ? state.takenBy(repo, workspaces: lists.slack.list) : nil
                let gone = !listed.contains(repo)
                Toggle(isOn: model.ticked(repo)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gone ? "\(repo) (not a project)" : repo).foregroundStyle(gone || taken != nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        if let taken { Text("Sends through \(taken)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .tint(Theme.accent)
                if let rule { ruleRows(rule) }
            }
            if choices.isEmpty { Text("No projects yet. Add one under Projects first.").foregroundStyle(.secondary) }
        } header: {
            Text("Projects")
        } footer: {
            Text("The projects whose sessions may send through this workspace. A project sends through one workspace at most.")
        }
        .listRowBackground(Theme.row)
    }

    /// A ticked project's channels, direct messages and approval, indented under its switch.
    @ViewBuilder private func ruleRows(_ rule: SlackProjectRule) -> some View {
        Group {
            SettingsTextRow(def: SettingsField(key: nil, kind: .text, label: "Channels", cue: "general, deploys",
                                               hint: "The channel names or ids its sessions may post to, separated by commas. Leave empty for none: it then writes only to people, if allowed below.",
                                               mono: true),
                            text: model.channels(rule.repo), focus: $focus, key: .channels(rule.repo))
            Toggle("May write direct messages to people", isOn: model.directMessages(rule.repo)).tint(Theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Picker("Approval", selection: model.allow(rule.repo)) {
                    Text("Ask before each message").tag(false)
                    Text("Send at once").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(rule.allow
                     ? "Messages go out as soon as a session sends them, except in a turn a webhook or a Slack reply started, which always asks."
                     : "Each message waits in the attention inbox until you approve it, for a day at most.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
        .padding(.leading, 16)
    }

    private func field(_ f: SlackWorkspaceField) -> some View {
        var def = f.def
        // The token's and the secret's boxes say whether one is stored.
        def.cue = state.cue(f)
        return SettingsTextRow(def: def, text: model.binding(f), focus: $focus, key: .field(f))
    }
}
