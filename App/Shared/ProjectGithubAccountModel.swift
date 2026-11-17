// The GitHub account the server uses for one project: the identity (`GET /github/account`, which makes no GitHub
// request) and an admin's health check (`GET /settings/github/health`), run only on a tap. Nothing is polled.
// ProjectSettingsScreen owns one for as long as the screen lives, so a check that is still running when the screen is
// covered (another tab, ··· → Clone) answers into it and is there on return; the screen reads the identity as it comes
// up. The board and a pull request own one too, for any token that can read the project: its GitHub account section
// (GithubAccountSection) reads the identity only when tapped, and a GitHub refusal on the same screen reads it once while
// shown, to name the account (GithubRefusalNote), so the screen reads it at most once. Which identity wins when a read
// and a check both answer is Core's `ProjectGithubAccountState`.
import SwiftUI

@MainActor
final class ProjectGithubAccountModel: ObservableObject {
    /// The saved project's repository (`ProjectFormState.githubRepo`); nil for a new project or a clone, which show nothing.
    let repo: String?
    /// The identity and the last check, kept by Core's rule that a verified identity outlives a later read.
    @Published private(set) var state = ProjectGithubAccountState()
    var identity: GithubAccountIdentity? { state.identity }
    /// The last check's answer, for as long as the model's owner lives.
    var health: GithubAccountHealth? { state.health }
    /// The identity was read, or refused; a read only left behind is asked again the next time the screen comes up.
    @Published private(set) var loaded = false
    /// The identity is being read.
    @Published private(set) var reading = false
    @Published private(set) var loadError: String?
    @Published private(set) var checking = false
    @Published private(set) var checkError: String?

    init(repo: String?) { self.repo = repo }

    /// Whether there is a saved project and the server says which account serves it; any token held to it may ask.
    var canRead: Bool { repo != nil && Store.shared.supports("github_account") }
    /// Whether this token may run the check: an Admin token, on a server that offers it.
    var canCheck: Bool { Store.shared.supports("settings_github_health") }

    func load() async {
        guard !loaded, !reading, canRead, let repo else { return }
        reading = true
        defer { reading = false }
        do {
            let r = try await Store.shared.call("github_account", ["repo": .string(repo)])
            state.read(GithubAccountIdentity(r))
            loadError = identity == nil ? settingsUnexpectedResponse : nil
            loaded = true
        } catch {
            guard let text = failure(error) else { return }
            loadError = text
            loaded = true
        }
    }

    /// Checks the account against GitHub now; its answer also refreshes the identity (the login GitHub verified). It is
    /// one request, left to finish whatever the screen does meanwhile, so its answer is never lost to a covered screen.
    func check() {
        guard !checking, canCheck, let repo else { return }
        checking = true
        checkError = nil
        Task {
            defer { checking = false }
            do {
                let r = try await Store.shared.call("settings_github_health", ["repo": .string(repo)])
                guard let h = GithubAccountHealth(r) else { checkError = settingsUnexpectedResponse; return }
                state.checked(h)
                if h.account != nil { loadError = nil }
            } catch {
                checkError = failure(error)
            }
        }
    }
}
