// The SSH server form's model: the form's state, reading the stored database login once the Database tab shows, and
// saving, cloning and deleting through /settings/ssh/servers, which needs an Admin token.
import SwiftUI

@MainActor
final class SSHServerFormModel: ObservableObject {
    /// The open tab stays open from one server to the next, as the other settings forms' do.
    static var openTab: SSHServerTab = .server
    /// The box a clone opens on: its label.
    static var pendingFocus: SSHServerField?

    @Published var state: SSHServerFormState
    @Published var tab: SSHServerTab { didSet { Self.openTab = tab; if tab == .database { readLogin() } } }
    /// Reading the stored database login, and why the last read failed.
    @Published var readingLogin = false
    @Published var loginError: String?
    @Published var saving = false
    @Published var deleting = false
    @Published var error: String?
    @Published var scrollToken = 0
    let defaults: JSON?
    var focusFirst: SSHServerField?

    init(row: JSON?, defaults: JSON?) {
        let r: JSON = row?.isObject == true ? row! : defaults?.isObject == true ? defaults! : [:]
        // A new server starts on the first project, as the web's form does, and where its label is typed.
        let s = SSHServerFormState(row: r, firstRepo: SettingsModel.shared.projects.list.first?["repo"].nonEmpty,
                                   database: Store.shared.supports("ssh_server_db_credentials"),
                                   passwords: SSHServerFormState.takesPasswords(SettingsModel.shared.ssh.list))
        state = s
        self.defaults = defaults
        if s.id == 0 && row == nil { focusFirst = .label; Self.openTab = .server }
        if let f = Self.pendingFocus { focusFirst = f; Self.pendingFocus = nil; Self.openTab = f.tab }
        if !s.offersDatabase { Self.openTab = .server }
        tab = Self.openTab
        if tab == .database { readLogin() }
    }

    var busy: Bool { saving || deleting }
    func tabDot(_ t: SSHServerTab) -> Bool { state.dirty && state.tabChanged(t) }

    func binding(_ f: SSHServerField) -> Binding<String> {
        Binding(get: { self.state.text(f) }, set: { v in
            // The port boxes take digits only, five at most; the others up to 1024 characters, as their edits do.
            let value = f.def.kind == .number ? String(v.filter { $0.isASCII && $0.isNumber }.prefix(5)) : String(v.prefix(1024))
            guard value != self.state.text(f) else { return }
            self.state.texts[f] = value
            // A password typed replaces the stored one rather than removing it.
            if !value.isEmpty { self.state.clear.remove(f) }
            self.changed()
        })
    }
    func toggleClear(_ f: SSHServerField) { state.toggleClear(f); changed() }
    func toggle() { state.enabled.toggle(); changed() }

    private func changed() {
        if !state.dirty { state.dirty = true }
        guardLeaving { [weak self] in self?.canLeave() ?? true }
    }
    func canLeave() -> Bool {
        guard state.dirty else { return true }
        let message = state.discardMessage
        let leave = confirmDiscard(message)
        if leave { state.dirty = false }
        return leave
    }
    private func showError(_ text: String) { error = text; scrollToken += 1 }

    /// The login stored on the server, opened, into its boxes; once, the first time the Database tab shows.
    func readLogin() {
        guard state.id != 0, state.offersDatabase, !state.loginKnown, !readingLogin,
              Store.shared.supports("ssh_server_db_credentials") else { return }
        let id = state.id
        loginError = nil
        readingLogin = true
        Task {
            defer { readingLogin = false }
            do {
                let r = try await Store.shared.call("ssh_server_db_credentials", ["id": .number(id)])
                guard state.id == id, !state.loginKnown else { return }
                guard r["credentials"].isObject else { loginError = unexpectedResponse; return }
                state.loginRead(r["credentials"])
            } catch {
                guard !error.isCancellation, state.id == id else { return }
                loginError = errorText(error)
            }
        }
    }

    /// The project picker, as a menu under the pointer. A project that is gone stays picked rather than being swapped for
    /// another; the server refuses it on save.
    func pickRepo() {
        let repos = SettingsModel.shared.projects.list.compactMap { $0["repo"].string }
        let now = state.repo
        var items = repos.map { PopupMenu.Item(title: $0, checked: $0 == now) }
        if !now.isEmpty && !repos.contains(now) { items.append(PopupMenu.Item(title: "\(now) (not a project)", checked: true, enabled: false)) }
        if repos.isEmpty && now.isEmpty { items.append(PopupMenu.Item(title: "No projects yet", enabled: false)) }
        guard let chosen = PopupMenu.choose(items), repos.indices.contains(chosen), repos[chosen] != now else { return }
        state.repo = repos[chosen]
        changed()
    }
    func pickMode() {
        let modes = ["ask", "allow"]
        guard let chosen = PopupMenu.choose(modes.map { PopupMenu.Item(title: SSHServerFormState.modeTitle($0), checked: $0 == state.mode) }),
              modes.indices.contains(chosen), modes[chosen] != state.mode else { return }
        state.mode = modes[chosen]
        changed()
    }

    func save() {
        let id = state.id
        guard !busy, Store.shared.supports(state.saveOperation) else { return }
        let body: JSON
        switch state.saveRequest() {
        case .failure(let p): tab = SSHServerTab(rawValue: p.tab) ?? .server; showError(p.message); return
        case .success(let b): body = b
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                let r = try await Store.shared.call(state.saveOperation, body)
                let row = r["server"]
                guard row.isObject else { showError(unexpectedResponse); return }
                // The server's word on what was saved: an empty label is now user@host:port, and a new server has an id.
                error = nil
                state.saved(row, sent: body)
                readLoginIfShown()
                post(.sshServersChanged)
                if id == 0 { Navigator.shared.show(.sshServerSettings(row: row, defaults: defaults)) }
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }

    func delete() {
        guard state.id != 0, !busy else { return }
        let name = state.row["label"].nonEmpty ?? "this SSH server"
        guard Dialogs.confirm("Delete \(name)?", "Sessions lose access through the SSH tool and pending approvals are cancelled.",
                              continueLabel: "Delete", destructive: true) else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await Store.shared.call("delete_ssh_server", ["id": .number(state.id)])
                state.dirty = false
                Navigator.shared.clear()
                post(.sshServersChanged)
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }

    private func readLoginIfShown() { if tab == .database { readLogin() } }

    func clone() {
        let copy: JSON
        switch state.copy() {
        case .failure(let p): tab = SSHServerTab(rawValue: p.tab) ?? .server; showError(p.message); return
        case .success(let c): copy = c
        }
        // The copy carries what the form holds now, saved or not, its database login too, without the label that named
        // this one.
        state.dirty = false
        Self.pendingFocus = .label
        Navigator.shared.show(.sshServerSettings(row: copy, defaults: nil))
    }
}
