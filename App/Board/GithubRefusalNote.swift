// GitHub's refusal to read something for a project, as the board, issue and pull request screens show it (`githubRefusal`
// in Core): which account it was read with and what it needs, then the server's words; or, when the server has no GitHub
// token for the repository at all, only that. The account is named once its identity is read (`GET /github/account`,
// which asks GitHub nothing), only while a refusal is shown, once, and never polled.
import SwiftUI

struct GithubRefusalNote: View {
    let subject: GithubReadSubject
    let error: String?
    @StateObject private var account: ProjectGithubAccountModel

    init(_ subject: GithubReadSubject, error: String?, repo: String) {
        self.subject = subject
        self.error = error
        _account = StateObject(wrappedValue: ProjectGithubAccountModel(repo: repo))
    }

    var body: some View {
        let refusal = githubRefusal(subject, error: error, account: account.identity)
        if let note = refusal.note {
            Text(verbatim: note).font(.footnote).foregroundStyle(.secondary)
                .task { await account.load() }
        }
        if let notice = refusal.notice { ErrorNotice(message: notice) }
    }
}
