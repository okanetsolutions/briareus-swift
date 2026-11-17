// GitHub's refusal to read something for a project, as the board, issue and pull request screens show it (`githubRefusal`
// in Core): which account it was read with and what it needs, then the server's words; or, when the server has no GitHub
// token for the repository at all, only that.
import SwiftUI

struct GithubRefusalNote: View {
    let refusal: GithubRefusal

    var body: some View {
        if !refusal.missingToken {
            Text(verbatim: refusal.explanation).font(.footnote).foregroundStyle(.secondary)
        }
        if let message = refusal.missingToken ? refusal.explanation : refusal.detail {
            ErrorNotice(message: message)
        }
    }
}
