// The GitHub account form's state and its saves on the Mac: the boxes and ticks over Core's GithubAccountFormState, Save
// and Delete through /settings/github/accounts (an Admin token's), and the guard that asks before unsaved changes go. The
// token typed is sent only in the save's body; it is never kept once saved, logged or put back in its box.
import SwiftUI

@MainActor
final class GithubAccountFormModel: ObservableObject {
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
    var tabDot: Bool { state.dirty && state.changed }

    func binding(_ f: GithubAccountField) -> Binding<String> {
        Binding(get: { self.state.text(f) }, set: { v in if self.state.edit(f, v) { self.changed() } })
    }
    func toggle(_ repo: String) { state.toggle(repo); changed() }

    /// The form was edited: leaving it now asks first.
    private func changed() { guardLeaving { [weak self] in self?.canLeave() ?? true } }
    func canLeave() -> Bool {
        guard state.dirty else { return true }
        let leave = confirmDiscard(state.discardMessage)
        if leave { state.dirty = false }
        return leave
    }
    private func showError(_ text: String) { error = text; scrollToken += 1 }
    /// A refusal as the form tells it: a project another account serves in words that say what to do, else the server's.
    private func refusal(_ error: Error) -> String { GithubAccountFormState.refusal(error, otherwise: errorText(error)) }

    func save() {
        let id = state.id
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
                guard let row = state.saved(r) else { showError(unexpectedResponse); return }
                error = nil
                post(.githubAccountsChanged)
                if id == 0 { Navigator.shared.show(.githubAccountSettings(row: row)) }
            } catch {
                if !error.isCancellation { showError(refusal(error)) }
            }
        }
    }

    func delete() {
        guard state.id != 0, !busy else { return }
        guard Dialogs.confirm("Delete \(state.name)?", "Its stored token is removed, and its projects read and write GitHub without it.",
                              continueLabel: "Delete", destructive: true) else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await Store.shared.call("delete_github_account", ["id": .number(state.id)])
                state.dirty = false
                Navigator.shared.clear()
                post(.githubAccountsChanged)
            } catch {
                if !error.isCancellation { showError(refusal(error)) }
            }
        }
    }
}
