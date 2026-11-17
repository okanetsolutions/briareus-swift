// The GitHub account the server uses for one project, as its settings show it (ProjectGithubAccountSection): the identity
// read when the section comes up (`GET /github/account`, which makes no GitHub request), and an admin's health check
// (`GET /settings/github/health`), run only on a tap. Nothing is polled or kept once the screen goes.
import SwiftUI

@MainActor
final class ProjectGithubAccountModel: ObservableObject {
    let repo: String
    @Published private(set) var identity: GithubAccountIdentity?
    /// The identity was read, or refused; a read only left behind is asked again the next time the section comes up.
    @Published private(set) var loaded = false
    @Published private(set) var loadError: String?
    /// The last check's answer, for as long as the screen is up.
    @Published private(set) var health: GithubAccountHealth?
    @Published private(set) var checking = false
    @Published private(set) var checkError: String?
    /// The check in flight, cancelled when the section goes (`stop()`).
    private var checkTask: Task<Void, Never>?

    init(repo: String) { self.repo = repo }

    /// Whether the server says which account serves a project; any token held to it may ask.
    var canRead: Bool { Store.shared.supports("github_account") }
    /// Whether this token may run the check: an Admin token, on a server that offers it.
    var canCheck: Bool { Store.shared.supports("settings_github_health") }

    func load() async {
        guard !loaded, canRead else { return }
        do {
            let r = try await Store.shared.call("github_account", ["repo": .string(repo)])
            let read = GithubAccountIdentity(r)
            // A check that answered first already set the identity GitHub verified; this read must not replace it.
            if health?.account == nil { identity = read }
            loadError = identity == nil ? settingsUnexpectedResponse : nil
            loaded = true
        } catch {
            guard let text = failure(error) else { return }
            loadError = text
            loaded = true
        }
    }

    /// Checks the account against GitHub now; its answer also refreshes the identity (the login GitHub verified).
    func check() {
        guard !checking, canCheck else { return }
        checking = true
        checkError = nil
        checkTask = Task {
            defer { checking = false; checkTask = nil }
            do {
                let r = try await Store.shared.call("settings_github_health", ["repo": .string(repo)])
                try Task.checkCancellation()
                guard let h = GithubAccountHealth(r) else { checkError = settingsUnexpectedResponse; return }
                health = h
                if let account = h.account { identity = account; loadError = nil }
            } catch {
                checkError = failure(error)
            }
        }
    }

    /// Stops a check still running, so leaving the screen does not leave the server reading GitHub for nobody.
    func stop() {
        checkTask?.cancel()
        checkTask = nil
    }
}
