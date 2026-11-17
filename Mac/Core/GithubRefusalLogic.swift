// What both apps say when GitHub would not read something for a project: the board's issues, an issue's or a pull
// request's Projects, the project's ▦ Board. The server reads GitHub with the project's GitHub account (falling back to
// its GITHUB_TOKEN), so the refusal names that account, or the loaded identity when there is one. The core's
// `no GitHub token for <repo>` (neither an account nor GITHUB_TOKEN) is recognised and said plainly, here and in
// `APIError.description`, instead of as a generic failure. No UI here.
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
}

/// The repository named by the core's `no GitHub token for <repo>`, wherever it appears in `message`; nil for any other
/// message.
func missingGithubTokenRepo(_ message: String?) -> String? {
    guard let message, let range = message.range(of: "no GitHub token for ", options: .caseInsensitive) else { return nil }
    let rest = message[range.upperBound...].prefix { !$0.isWhitespace }
    let repo = rest.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)\"'"))
    return repo.isEmpty ? nil : repo
}

/// What the user is told when the server has no GitHub token for `repo`.
func missingGithubTokenText(_ repo: String) -> String {
    "The server has no GitHub token for \(repo): no GitHub account serves it and there is no GITHUB_TOKEN to fall back on. An admin can assign one in ⚙ Settings → GitHub accounts."
}

/// What a screen says when GitHub would not read `subject`: the account it was read with (`account` when the project's
/// identity is already loaded, else the project's account in general) and the permission it needs, then `error`.
func githubRefusal(_ subject: GithubReadSubject, error: String?, account: GithubAccountIdentity? = nil) -> GithubRefusal {
    if let repo = missingGithubTokenRepo(error) {
        return GithubRefusal(explanation: missingGithubTokenText(repo), detail: nil, missingToken: true)
    }
    let with = githubAccountPhrase(account)
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
