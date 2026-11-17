// GitHub's refusal to read something for a project, as the board, issue and pull request screens show it (`githubRefusal`
// in Core): which account it was read with and what it needs, then the server's words; or, when the server has no GitHub
// token for the repository at all, only that.
import SwiftUI

struct GithubRefusalNote: View {
    let refusal: GithubRefusal
    /// The explanation's text style: the footnote in a box, the caption in a sidebar.
    var font: Font = Theme.caption

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !refusal.missingToken {
                Text(verbatim: refusal.explanation).font(font).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let message = refusal.missingToken ? refusal.explanation : refusal.detail {
                Notice(message: message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The ▦ Board tab's refusal: the server's words boxed, then what reading a board needs; or only that there is no token.
struct GithubBoardRefusalNote: View {
    let refusal: GithubRefusal

    var body: some View {
        NoticeBox(message: refusal.detail ?? refusal.explanation)
        if !refusal.missingToken && refusal.detail != nil {
            Text(verbatim: refusal.explanation)
                .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6).padding(.bottom, 10)
        }
    }
}
