// A Slack workspace across the whole pane in one tab, as the Windows client's form has it: who it sends as, once a token
// is stored; Label and the write-only User OAuth token side by side, with the scopes the token needs under them; the
// write-only signing secret; the Request URL for the Slack app's Event Subscriptions, with Copy; and the projects that may
// send through it, each ticked one with its channels, whether it may write to people and whether each message waits for
// approval. Projects another workspace already serves are marked. Saved through /settings/slack/workspaces, which needs
// an Admin token.
import SwiftUI

/// A box of the form: one of its fields, or a ticked project's channels.
enum SlackFormFocus: Hashable {
    case field(SlackWorkspaceField)
    case channels(String)
}

@MainActor
final class SlackWorkspaceFormModel: ObservableObject {
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
    var tabDot: Bool { state.dirty && state.changed }

    func binding(_ f: SlackWorkspaceField) -> Binding<String> {
        Binding(get: { self.state.text(f) }, set: { v in
            let value = String(v.prefix(f.limit))
            guard value != self.state.text(f) else { return }
            self.state.texts[f] = value
            self.changed()
        })
    }
    func channels(_ repo: String) -> Binding<String> {
        Binding(get: { self.state.rule(repo)?.channels ?? "" }, set: { v in
            let value = String(v.prefix(2000))
            guard let i = self.state.projects.firstIndex(where: { $0.repo == repo }), self.state.projects[i].channels != value else { return }
            self.state.projects[i].channels = value
            self.changed()
        })
    }
    func toggle(_ repo: String) { state.toggle(repo); changed() }
    func toggleDirectMessages(_ repo: String) {
        guard let i = state.projects.firstIndex(where: { $0.repo == repo }) else { return }
        state.projects[i].directMessages.toggle()
        changed()
    }
    func setAllow(_ repo: String, _ allow: Bool) {
        guard let i = state.projects.firstIndex(where: { $0.repo == repo }), state.projects[i].allow != allow else { return }
        state.projects[i].allow = allow
        changed()
    }

    private func changed() {
        if !state.dirty { state.dirty = true }
        guardLeaving { [weak self] in self?.canLeave() ?? true }
    }
    func canLeave() -> Bool {
        guard state.dirty else { return true }
        let message = state.id != 0 ? "The changes to \(state.row["label"].nonEmpty ?? "this Slack workspace") have not been saved." : "The new Slack workspace has not been saved."
        let leave = confirmDiscard(message)
        if leave { state.dirty = false }
        return leave
    }
    private func showError(_ text: String) { error = text; scrollToken += 1 }

    func save() {
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
                guard row.isObject else { showError(unexpectedResponse); return }
                // The server's word on what was saved: who the token is, an empty label now the workspace's name, and a new
                // workspace's id and Request URL.
                error = nil
                state.row = row
                state.fill()
                post(.slackWorkspacesChanged)
                if id == 0 { Navigator.shared.show(.slackWorkspaceSettings(row: row, defaults: SettingsModel.shared.slack.defaults)) }
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }

    func delete() {
        guard state.id != 0, !busy else { return }
        let name = state.row["label"].nonEmpty ?? "this Slack workspace"
        guard Dialogs.confirm("Delete \(name)?", "Its stored token and signing secret are removed: its projects' sessions can no longer send Slack messages, and replies stop reaching them.",
                              continueLabel: "Delete", destructive: true) else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await Store.shared.call("delete_slack_workspace", ["id": .number(state.id)])
                state.dirty = false
                Navigator.shared.clear()
                post(.slackWorkspacesChanged)
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }
}

struct SlackWorkspaceSettingsScreen: View {
    var row: JSON?
    var defaults: JSON?
    @StateObject private var model: SlackWorkspaceFormModel
    /// The projects, and the other workspaces whose projects this form marks as taken.
    @ObservedObject private var settings = SettingsModel.shared
    @FocusState private var focus: SlackFormFocus?
    @EnvironmentObject private var store: Store

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: SlackWorkspaceFormModel(row: row, defaults: defaults))
    }

    private var state: SlackWorkspaceFormState { model.state }

    var body: some View {
        SettingsPage(header: header,
                     unavailable: settingsUnavailable("settings_slack_workspaces", path: "settings/slack/workspaces", what: "Slack workspaces", manage: "them"),
                     scrollToken: model.scrollToken) {
            SettingsTabs(tabs: [SettingsTabs.Tab(id: 0, title: "Slack workspace", glyph: Glyph.symbol(0xE8BD), dot: model.tabDot)], open: 0) { _ in }
            if let error = model.error { NoticeBox(message: error).padding(.bottom, 16) }
            if state.id != 0 && state.hasToken { connection }
            // Label and token side by side, as the Forge form's label and organization; the scopes the token needs across
            // under them.
            SettingsPair { field(.label) } right: { field(.token) }
            SettingsNote(text: "Create a Slack app at api.slack.com/apps and give it these user token scopes under OAuth & Permissions: \(SlackWorkspaceFormState.scopes). Install it to the workspace, then paste its User OAuth Token.", after: 14)
                .padding(.top, -8)
            field(.signingSecret)
            events
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

    /// Who the workspace's messages go out as, from Slack, once a token is stored.
    private var connection: some View {
        Card(padding: 12, radius: 6) {
            VStack(alignment: .leading, spacing: 4) {
                SettingsStatusRow(label: "Workspace", value: state.row["team"].nonEmpty ?? "—")
                if let url = state.row["url"].nonEmpty { SettingsStatusRow(label: "Address", value: url) }
                SettingsStatusRow(label: "Sends as", value: state.row["user"].nonEmpty ?? "—")
            }
        }
        .padding(.bottom, 18)
    }

    /// Where Slack sends the replies: the Request URL for the app's Event Subscriptions, with a Copy button.
    private var events: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsFieldLabel(label: "Request URL",
                               hint: "Turn on the Slack app's Event Subscriptions with this as the Request URL, and subscribe on behalf of users to message.im, message.channels and message.groups. Like the server's other webhooks, the path must bypass Cloudflare Access.")
            if state.id == 0 {
                SettingsHint(text: "Save the workspace to get the Request URL its replies come back through.")
            } else if let url = state.row["eventsUrl"].nonEmpty {
                HStack(spacing: 14) {
                    Text(url).font(Theme.mono).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                    Button("Copy") { Clipboard.copy(url) }.dashButton(.plain)
                    Spacer(minLength: 0)
                }
                SettingsHint(text: "Subscribe on behalf of users to message.im, message.channels and message.groups.").padding(.top, 6)
                if !state.hasSigningSecret {
                    SettingsHint(text: "Replies reach the sessions once the signing secret is saved.").padding(.top, 4)
                }
            } else {
                SettingsHint(text: "The server has no public address (PUBLIC_BASE_URL), so it has no Request URL to give Slack: messages can be sent, but replies do not reach the sessions.")
            }
        }
        .padding(.bottom, 18)
    }

    /// The projects that may send through the workspace, one tick box each; a ticked one opens its channels, whether it may
    /// write to people and whether each message waits for approval.
    @ViewBuilder private var projects: some View {
        let listed = settings.projects.list.compactMap { $0["repo"].nonEmpty }
        let choices = settingsRepoChoices(projects: listed, ticked: state.projects.map(\.repo))
        VStack(alignment: .leading, spacing: 0) {
            SettingsFieldLabel(label: "Projects", hint: "The projects whose sessions may send through this workspace. A project sends through one workspace at most.")
            ForEach(choices, id: \.self) { repo in
                let rule = state.rule(repo)
                let taken = rule == nil ? state.takenBy(repo, workspaces: settings.slack.list) : nil
                let gone = !listed.contains(repo)
                SettingsCheck(label: gone ? "\(repo) (not a project)" : taken.map { "\(repo) · sends through \($0)" } ?? repo,
                              on: rule != nil, height: 28, muted: gone || taken != nil) { model.toggle(repo) }
                if let rule { ruleBox(rule) }
            }
            if choices.isEmpty { SettingsHint(text: "No projects yet. Add one under Projects first.") }
        }
        .padding(.bottom, 14)
    }

    /// A ticked project's channels, direct messages and approval, indented under its tick box.
    private func ruleBox(_ rule: SlackProjectRule) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsFieldBox(def: SettingsField(key: nil, kind: .text, label: "Channels", cue: "general, deploys",
                                                hint: "The channel names or ids its sessions may post to, separated by commas. Leave empty for none: it then writes only to people, if allowed below.",
                                                mono: true),
                             text: model.channels(rule.repo), focus: $focus, key: .channels(rule.repo)) { focus = next(after: .channels(rule.repo)) }
                .padding(.bottom, -6)
            SettingsCheck(label: "May write direct messages to people", on: rule.directMessages, height: 28) { model.toggleDirectMessages(rule.repo) }
                .padding(.bottom, 6)
            Segments(titles: ["Ask before each message", "Send at once"], selected: rule.allow ? 1 : 0, dangerFirst: false) { i in
                model.setAllow(rule.repo, i == 1)
            }
            .padding(.bottom, 6)
            SettingsHint(text: rule.allow
                ? "Messages go out as soon as a session sends them, except in a turn a webhook or a Slack reply started, which always asks."
                : "Each message waits in the attention inbox until you approve it, for a day at most.")
        }
        .padding(.leading, 23).padding(.top, 4).padding(.bottom, 14)
    }

    private var header: PaneHeader {
        let id = state.id
        var buttons: [HeaderButton] = []
        if store.supports("settings_slack_workspaces") {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74E), label: model.saving ? "Saving…" : "Save", tip: "Save this Slack workspace (⌘S)",
                                        enabled: !model.busy && (state.dirty || id == 0) && store.supports(id != 0 ? "update_slack_workspace" : "create_slack_workspace"),
                                        prominent: true) { model.save() })
            if id != 0 {
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74D), tip: "Delete this Slack workspace",
                                            enabled: !model.busy && store.supports("delete_slack_workspace"), destructive: true) { model.delete() })
            }
        }
        return id != 0
            ? PaneHeader(title: state.row["label"].nonEmpty ?? state.row["team"].nonEmpty ?? "Slack workspace",
                         subtitle: SlackWorkspaceFormState.subtitle(state.row), buttons: buttons)
            : PaneHeader(title: "New Slack workspace", subtitle: "Sessions send Slack messages as you, and hear the replies.", buttons: buttons)
    }

    private func field(_ f: SlackWorkspaceField) -> some View {
        var def = f.def
        // The token's and the secret's boxes say whether one is stored.
        def.cue = state.cue(f)
        return SettingsFieldBox(def: def, text: model.binding(f), focus: $focus, key: .field(f)) { focus = next(after: .field(f)) }
    }

    /// The box after this one, for Return: the fields', then each ticked project's channels, round to the first.
    private func next(after k: SlackFormFocus) -> SlackFormFocus {
        let order = SlackWorkspaceField.allCases.map(SlackFormFocus.field) + state.projects.map { SlackFormFocus.channels($0.repo) }
        guard let i = order.firstIndex(of: k) else { return k }
        return order[(i + 1) % order.count]
    }
}
