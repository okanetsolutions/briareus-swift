// The GitHub account the server uses for one project: the identity (`GET /github/account`, which makes no GitHub
// request) and an admin's health check (`GET /settings/github/health`), run only on a click. Nothing is polled.
// ProjectGithubAccountSection owns one for as long as its project's settings are open, across their tabs, so a check
// answers into it whichever tab is showing and is there on return, as on the iPhone; it reads the identity when the
// Project tab first shows. PullScreen owns one too, whose identity its sidebar (PullGithubAccountItem) reads only when
// clicked, for any token that can read the project; and the board, issue and pull request screens read it once while a
// GitHub refusal is shown, to name the account (GithubRefusalNote).
import SwiftUI

@MainActor
final class ProjectGithubAccountModel: ObservableObject {
    let repo: String
    @Published private(set) var identity: GithubAccountIdentity?
    /// The identity was read, or refused; a read only left behind is asked again the next time the section comes up.
    @Published private(set) var loaded = false
    /// The identity is being read.
    @Published private(set) var reading = false
    @Published private(set) var loadError: String?
    /// The last check's answer, for as long as the model's owner lives.
    @Published private(set) var health: GithubAccountHealth?
    @Published private(set) var checking = false
    @Published private(set) var checkError: String?

    init(repo: String) { self.repo = repo }

    /// Whether the server says which account serves a project; any token held to it may ask.
    static var offered: Bool { Store.shared.supports("github_account") }
    var canRead: Bool { Self.offered }
    /// Whether this token may run the check: an Admin token, on a server that offers it.
    var canCheck: Bool { Store.shared.supports("settings_github_health") }

    func load() async {
        guard !loaded, !reading, canRead else { return }
        reading = true
        defer { reading = false }
        do {
            let r = try await Store.shared.call("github_account", ["repo": .string(repo)])
            let read = GithubAccountIdentity(r)
            // A check that answered first already set the identity GitHub verified; this read must not replace it.
            if health?.account == nil { identity = read }
            loadError = identity == nil ? unexpectedResponse : nil
            loaded = true
        } catch {
            guard !error.isCancellation else { return }
            loadError = errorText(error)
            loaded = true
        }
    }

    /// Checks the account against GitHub now; its answer also refreshes the identity (the login GitHub verified). It is
    /// one request, left to finish whatever the screen does meanwhile, so its answer is never lost to another tab.
    func check() {
        guard !checking, canCheck else { return }
        checking = true
        checkError = nil
        Task {
            defer { checking = false }
            do {
                let r = try await Store.shared.call("settings_github_health", ["repo": .string(repo)])
                guard let h = GithubAccountHealth(r) else { checkError = unexpectedResponse; return }
                health = h
                if let account = h.account { identity = account; loadError = nil }
            } catch {
                if !error.isCancellation { checkError = errorText(error) }
            }
        }
    }
}
