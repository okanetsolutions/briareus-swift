// What both apps say when GitHub would not read something for a project: the board's issues, an issue's or a pull
// request's Projects, the project's ▦ Board. The server reads GitHub with the project's GitHub account (falling back to
// its GITHUB_TOKEN), so the refusal names that account, or the loaded identity when there is one. The core's 503
// `no GitHub token for <repo>` (the project's account has no usable token, or none is assigned and there is no
// GITHUB_TOKEN) is recognised by its whole message and said plainly, naming which when the identity is loaded, here and
// in `APIError.description` (in a few words on CarPlay, `CarText`), instead of as a generic failure. No UI here.
import Foundation

/// What GitHub would not read.
enum GithubReadSubject: Equatable, Sendable {
    /// The board's Issues list (`issuesError`).
    case issues
    /// An issue's Projects, or those of the issues a pull request closes (`projectsError`).
    case projects
    /// The project's Projects v2 board (the Mac's ▦ Board tab).
    case board
}

/// A refusal as a screen shows it: the explanation, then GitHub's own words when they add anything.
struct GithubRefusal: Equatable, Sendable {
    var explanation: String
    /// The server's message, shown under the explanation; nil when the explanation already says it all.
    var detail: String?
    /// The server had no GitHub token for the repository at all, rather than one GitHub turned away.
    var missingToken: Bool

    /// The muted explanation drawn above the notice; nil when the notice already says it (a missing token). Only a
    /// refusal with a note names the account, so only it is worth reading the project's identity for.
    var note: String? { missingToken ? nil : explanation }
    /// The red notice: the missing token's explanation, else the server's words when there are any.
    var notice: String? { missingToken ? explanation : detail }
}

/// What the core says, and all it says, when it has no GitHub token for a repository (`lib/github-config.js`, answered with
/// a 503): the project's assigned account has none it can use (the core does not fall back to GITHUB_TOKEN then), or no
/// account is assigned and there is no GITHUB_TOKEN.
private let missingGithubTokenPrefix = "no GitHub token for "

/// The repository named by the core's `no GitHub token for <repo>` when that is the whole of `message`; nil for any
/// other message, including one that only mentions it.
func missingGithubTokenRepo(_ message: String?) -> String? {
    guard let text = message?.trimmingCharacters(in: .whitespacesAndNewlines),
          text.hasPrefix(missingGithubTokenPrefix) else { return nil }
    let repo = text.dropFirst(missingGithubTokenPrefix.count)
    return repo.isEmpty || repo.contains(where: \.isWhitespace) ? nil : String(repo)
}

/// Why the core had no GitHub token for a project, as far as the project's identity tells.
enum MissingGithubTokenCause: Equatable, Sendable {
    /// The project's assigned account has no usable token; `label` is empty for an unlabelled one.
    case accountHasNoToken(label: String)
    /// No account serves the project and the server has no GITHUB_TOKEN.
    case noAccountNorFallback
    /// The identity is not loaded, so it is either.
    case unknown

    init(_ account: GithubAccountIdentity?) {
        guard let account else { self = .unknown; return }
        self = account.globalFallback ? .noAccountNorFallback : .accountHasNoToken(label: account.label)
    }
}

/// What the user is told when the server has no GitHub token for `repo`: which cause, when the project's identity
/// (`account`) is loaded, else both.
func missingGithubTokenText(_ repo: String, account: GithubAccountIdentity? = nil) -> String {
    let why: String
    switch MissingGithubTokenCause(account) {
    case .accountHasNoToken(let label):
        why = label.isEmpty ? "its GitHub account has no usable token" : "its GitHub account \(label) has no usable token"
    case .noAccountNorFallback:
        why = "no GitHub account serves it and there is no GITHUB_TOKEN to fall back on"
    case .unknown:
        why = "its GitHub account has no usable token, or none is assigned and there is no GITHUB_TOKEN to fall back on"
    }
    return "The server has no GitHub token for \(repo): \(why). An admin can fix it in ⚙ Settings → GitHub accounts."
}

/// What a screen says when GitHub would not read `subject`: the account it was read with (`account` when the project's
/// identity is already loaded, else the project's account in general) and the permission it needs, then `error`; or,
/// for the core's missing token, why it has none.
func githubRefusal(_ subject: GithubReadSubject, error: String?, account: GithubAccountIdentity? = nil) -> GithubRefusal {
    if let repo = missingGithubTokenRepo(error) {
        return GithubRefusal(explanation: missingGithubTokenText(repo, account: account), detail: nil, missingToken: true)
    }
    let with = refusingAccountPhrase(account)
    let explanation: String
    switch subject {
    case .issues:
        explanation = "GitHub would not read this repository’s issues with \(with). A fine-grained token needs Issues: read. The pull requests are unaffected."
    case .projects:
        explanation = "GitHub would not read the projects with \(with), which needs Projects: read."
    case .board:
        explanation = "Reading a board needs Projects: read on \(with) (read:project on a classic token), and a project and view GitHub can find. The board is named in ⚙ Settings → Projects."
    }
    let detail = error?.trimmingCharacters(in: .whitespacesAndNewlines)
    return GithubRefusal(explanation: explanation, detail: detail?.isEmpty == false ? detail : nil, missingToken: false)
}

/// The account a refusal says GitHub was asked with. An identity holding no token at all, which `githubAccountPhrase`
/// says as "no GitHub token", cannot follow "with", so the project's account is named in general instead.
private func refusingAccountPhrase(_ account: GithubAccountIdentity?) -> String {
    guard let account, !account.hasToken, account.globalFallback || account.label.isEmpty else {
        return githubAccountPhrase(account)
    }
    return githubAccountPhrase(nil)
}

extension APIError {
    /// A board's `issuesError` as the failure it stands for: the core's missing GitHub token is its 503, anything else
    /// GitHub refusing the read, a 502.
    static func githubRead(refused: String) -> APIError {
        APIError(.http, status: missingGithubTokenRepo(refused) == nil ? 502 : 503, message: refused)
    }
}
