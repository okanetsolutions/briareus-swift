// A project's GitHub account on the board's screens, on the Mac: the account the server reads and writes GitHub with for
// the project, shown on a click to any token that can read the project (the board, under its lists, and a pull request's
// sidebar), and GitHub's refusals to read for it, which name that account. A screen owns one ProjectGithubAccountModel
// and gives it to both, so the account is read at most once while the screen lives (`GET /github/account`, which asks
// GitHub nothing) and never polled, as on the iPhone (its GithubAccountPieces.swift).
import SwiftUI

/// The project's GitHub account as a sidebar item: Show GitHub account until it is read, then its line.
struct GithubAccountItem: View {
    @ObservedObject var account: ProjectGithubAccountModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("GitHub account").font(Theme.captionSemibold).foregroundStyle(Theme.muted).lineLimit(1).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 4) {
                if let identity = account.identity {
                    GithubHealthLine(symbol: identity.symbol, tone: identity.tone, title: identity.line)
                    if let detail = identity.detail {
                        Text(detail).font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                } else if let error = account.loadError {
                    Notice(message: error)
                } else if account.reading {
                    LoadingNote(text: "Reading the account…")
                } else {
                    Button { Task { await account.load() } } label: {
                        Label("Show GitHub account", systemImage: "person.badge.key")
                    }
                    .dashButton(.bordered)
                    .help("Read which GitHub account the server uses for this project")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The item boxed under the board's lists, on a server that says which account serves a project.
struct BoardGithubAccountBox: View {
    let account: ProjectGithubAccountModel

    var body: some View {
        if ProjectGithubAccountModel.offered { BoardBox { GithubAccountItem(account: account) }.padding(.top, 8) }
    }
}

/// GitHub's refusal to read something for a project, as the board, issue and pull request screens show it
/// (`githubRefusal` in Core): which account it was read with and what it needs, then the server's words; or, when the
/// server has no GitHub token for the repository, only why, naming the cause once the account is known. The account is
/// read only while a note is shown, once, through the screen's `account`.
struct GithubRefusalNote: View {
    let subject: GithubReadSubject
    let error: String?
    @ObservedObject var account: ProjectGithubAccountModel
    /// The explanation's text style: the footnote in a box, the caption in a sidebar.
    var font: Font
    /// The ▦ Board tab's layout: the server's words boxed first, the explanation under them.
    var boxed: Bool

    init(_ subject: GithubReadSubject, error: String?, account: ProjectGithubAccountModel, font: Font = Theme.caption, boxed: Bool = false) {
        self.subject = subject; self.error = error; self.account = account; self.font = font; self.boxed = boxed
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

/// A refusal on a screen that keeps no account of its own (an issue's Projects, the ▦ Board tab): the note with an
/// account it owns. A call site gives it `.id(repo)`, so a note reused for another repository reads that one's identity.
struct StandaloneGithubRefusalNote: View {
    let subject: GithubReadSubject
    let error: String?
    var font: Font
    var boxed: Bool
    @StateObject private var account: ProjectGithubAccountModel

    init(_ subject: GithubReadSubject, error: String?, repo: String, font: Font = Theme.caption, boxed: Bool = false) {
        self.subject = subject; self.error = error; self.font = font; self.boxed = boxed
        _account = StateObject(wrappedValue: ProjectGithubAccountModel(repo: repo))
    }

    var body: some View { GithubRefusalNote(subject, error: error, account: account, font: font, boxed: boxed) }
}
