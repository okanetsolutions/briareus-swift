// GitHub's refusal to read something for a project, as the board, issue and pull request screens show it (`githubRefusal`
// in Core): which account it was read with and what it needs, then the server's words; or, when the server has no GitHub
// token for the repository at all, only that. The account is named once its identity is read (`GET /github/account`,
// which asks GitHub nothing), only while a refusal is shown, once, and never polled, as on the iPhone. A call site gives
// it `.id(repo)`, so a note reused for another repository reads that one's identity.
import SwiftUI

struct GithubRefusalNote: View {
    let subject: GithubReadSubject
    let error: String?
    /// The explanation's text style: the footnote in a box, the caption in a sidebar.
    var font: Font
    /// The ▦ Board tab's layout: the server's words boxed first, the explanation under them.
    var boxed: Bool
    @StateObject private var account: ProjectGithubAccountModel

    init(_ subject: GithubReadSubject, error: String?, repo: String, font: Font = Theme.caption, boxed: Bool = false) {
        self.subject = subject; self.error = error; self.font = font; self.boxed = boxed
        _account = StateObject(wrappedValue: ProjectGithubAccountModel(repo: repo))
    }

    var body: some View {
        let refusal = githubRefusal(subject, error: error, account: account.identity)
        VStack(alignment: .leading, spacing: 6) {
            if boxed, let notice = refusal.notice { NoticeBox(message: notice) }
            if let note = refusal.note {
                Text(verbatim: note).font(font).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    .task { await account.load() }
            }
            if !boxed, let notice = refusal.notice { Notice(message: notice) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, boxed ? 10 : 0)
    }
}
