// The SSH server form's model on a phone: the form's state, reading the stored database login once the Database tab
// shows, and saving, cloning and deleting through /settings/ssh/servers, which needs an Admin token.
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
        let s = SSHServerFormState(row: r, firstRepo: SettingsLists.shared.projects.list.first?["repo"].nonEmpty,
                                   database: Store.shared.supports("ssh_server_db_credentials"),
                                   passwords: SSHServerFormState.takesPasswords(SettingsLists.shared.ssh.list))
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
    var enabledBinding: Binding<Bool> {
        Binding(get: { self.state.enabled }, set: { v in guard v != self.state.enabled else { return }; self.state.enabled = v; self.changed() })
    }
    var repoBinding: Binding<String> {
        Binding(get: { self.state.repo }, set: { v in guard v != self.state.repo else { return }; self.state.repo = v; self.changed() })
    }
    var modeBinding: Binding<String> {
        Binding(get: { self.state.mode }, set: { v in guard v != self.state.mode else { return }; self.state.mode = v; self.changed() })
    }

    private func changed() { if !state.dirty { state.dirty = true } }
    var discardMessage: String {
        state.discardMessage
    }
    private func showError(_ text: String?) {
        guard let text else { return }
        error = text; scrollToken += 1
    }

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
                guard r["credentials"].isObject else { loginError = settingsUnexpectedResponse; return }
                state.loginRead(r["credentials"])
            } catch {
                guard state.id == id, let text = failure(error) else { return }
                loginError = text
            }
        }
    }

    func save(done: @escaping () -> Void) {
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
                guard row.isObject else { showError(settingsUnexpectedResponse); return }
                // The server's word on what was saved: an empty label is now user@host:port, and a new server has an id.
                error = nil
                state.saved(row, sent: body)
                Task { try? await SettingsLists.shared.loadSSH() }
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
                try await Store.shared.call("delete_ssh_server", ["id": .number(state.id)])
                state.dirty = false
                Task { try? await SettingsLists.shared.loadSSH() }
                done()
            } catch {
                showError(failure(error))
            }
        }
    }

    /// What a clone starts from: what the form holds now, saved or not, its database login too, without the label that
    /// named this one.
    func cloneRow() -> JSON? {
        switch state.copy() {
        case .failure(let p): tab = SSHServerTab(rawValue: p.tab) ?? .server; showError(p.message); return nil
        case .success(let copy):
            Self.pendingFocus = .label
            return copy
        }
    }
}
