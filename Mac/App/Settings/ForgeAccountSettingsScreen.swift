// A Laravel Forge account across the whole pane in one tab, as the Windows client's form has it: Label and Organization
// side by side, then the write-only API token and the projects the account is available to, one tick box each. Saved
// through /settings/forge/accounts, which needs an Admin token.
import SwiftUI

@MainActor
final class ForgeAccountFormModel: ObservableObject {
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
    var tabDot: Bool { state.dirty && state.changed }

    func binding(_ f: ForgeAccountField) -> Binding<String> {
        Binding(get: { self.state.text(f) }, set: { v in
            let value = String(v.prefix(f.limit))
            guard value != self.state.text(f) else { return }
            self.state.texts[f] = value
            self.changed()
        })
    }
    func toggle(_ repo: String) { state.toggle(repo); changed() }

    private func changed() {
        if !state.dirty { state.dirty = true }
        guardLeaving { [weak self] in self?.canLeave() ?? true }
    }
    func canLeave() -> Bool {
        guard state.dirty else { return true }
        let message = state.id != 0 ? "The changes to \(state.row["label"].nonEmpty ?? "this Forge account") have not been saved." : "The new Forge account has not been saved."
        let leave = confirmDiscard(message)
        if leave { state.dirty = false }
        return leave
    }
    private func showError(_ text: String) { error = text; scrollToken += 1 }

    func save() {
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
                guard row.isObject else { showError(unexpectedResponse); return }
                // The server's word on what was saved: an empty label is now the organization, and a new account has an id.
                error = nil
                state.row = row
                state.fill()
                post(.forgeAccountsChanged)
                if id == 0 { Navigator.shared.show(.forgeAccountSettings(row: row, defaults: SettingsModel.shared.forge.defaults)) }
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }

    func delete() {
        guard state.id != 0, !busy else { return }
        let name = state.row["label"].nonEmpty ?? "this Forge account"
        guard Dialogs.confirm("Delete \(name)?", "Its stored token is removed and clients can no longer reach the organization's Forge servers and sites through it.",
                              continueLabel: "Delete", destructive: true) else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await Store.shared.call("delete_forge_account", ["id": .number(state.id)])
                state.dirty = false
                Navigator.shared.clear()
                post(.forgeAccountsChanged)
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }
}

struct ForgeAccountSettingsScreen: View {
    var row: JSON?
    var defaults: JSON?
    @StateObject private var model: ForgeAccountFormModel
    @ObservedObject private var settings = SettingsModel.shared
    @FocusState private var focus: ForgeAccountField?
    @EnvironmentObject private var store: Store

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: ForgeAccountFormModel(row: row, defaults: defaults))
    }

    private var state: ForgeAccountFormState { model.state }

    var body: some View {
        SettingsPage(header: header,
                     unavailable: settingsUnavailable("settings_forge_accounts", path: "settings/forge/accounts", what: "Forge accounts", manage: "them"),
                     scrollToken: model.scrollToken) {
            SettingsTabs(tabs: [SettingsTabs.Tab(id: 0, title: "Forge account", glyph: Glyph.symbol(0xE753), dot: model.tabDot)], open: 0) { _ in }
            if let error = model.error { NoticeBox(message: error).padding(.bottom, 16) }
            // Label and organization side by side, as the SSH form's `.field-row`; then the token and the projects across.
            SettingsPair { field(.label) } right: { field(.organization) }
            field(.token)
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

    /// The projects the account is available to, one tick box each, as the web form's multiple select.
    @ViewBuilder private var projects: some View {
        let listed = settings.projects.list.compactMap { $0["repo"].nonEmpty }
        let choices = settingsRepoChoices(projects: listed, ticked: state.repos)
        VStack(alignment: .leading, spacing: 0) {
            SettingsFieldLabel(label: "Projects", hint: "Only these projects offer the account's Forge servers and sites to their clients.")
            ForEach(choices, id: \.self) { repo in
                let gone = !listed.contains(repo)
                SettingsCheck(label: gone ? "\(repo) (not a project)" : repo, on: state.repos.contains(repo), height: 28, muted: gone) { model.toggle(repo) }
            }
            if choices.isEmpty { SettingsHint(text: "No projects yet. Add one under Projects first.") }
        }
        .padding(.bottom, 14)
    }

    private var header: PaneHeader {
        let id = state.id
        var buttons: [HeaderButton] = []
        if store.supports("settings_forge_accounts") {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74E), label: model.saving ? "Saving…" : "Save", tip: "Save this Forge account (⌘S)",
                                        enabled: !model.busy && (state.dirty || id == 0) && store.supports(id != 0 ? "update_forge_account" : "create_forge_account"),
                                        prominent: true) { model.save() })
            if id != 0 {
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74D), tip: "Delete this Forge account",
                                            enabled: !model.busy && store.supports("delete_forge_account"), destructive: true) { model.delete() })
            }
        }
        return id != 0
            ? PaneHeader(title: state.row["label"].nonEmpty ?? state.row["organization"].nonEmpty ?? "Forge account",
                         subtitle: ForgeAccountFormState.subtitle(state.row), buttons: buttons)
            : PaneHeader(title: "New Forge account", subtitle: "A Laravel Forge organization, and the projects whose clients may use it.", buttons: buttons)
    }

    private func field(_ f: ForgeAccountField) -> some View {
        var def = f.def
        // The token's box says whether one is stored.
        if f == .token { def.cue = state.tokenCue }
        return SettingsFieldBox(def: def, text: model.binding(f), focus: $focus, key: f) {
            let all = ForgeAccountField.allCases
            focus = all[((all.firstIndex(of: f) ?? 0) + 1) % all.count]
        }
    }
}
