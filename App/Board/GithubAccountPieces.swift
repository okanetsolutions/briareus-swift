// A project's GitHub account on the board's screens, on a phone: the account the server reads and writes GitHub with for
// the project, shown on a tap to any token that can read the project (the board, under its lists, and a pull request,
// under its description), and GitHub's refusals to read for it, which name that account. A screen owns one
// ProjectGithubAccountModel and gives it to both, so the account is read at most once while the screen lives
// (`GET /github/account`, which asks GitHub nothing) and never polled. The Mac's twins are in its GithubAccountPieces.swift.
import SwiftUI

/// The project's GitHub account as a section: Show GitHub account until it is read, then its line.
struct GithubAccountSection: View {
    @ObservedObject var account: ProjectGithubAccountModel

    var body: some View {
        if account.canRead {
            Section {
                if let identity = account.identity {
                    GithubHealthLine(symbol: identity.symbol, tone: identity.tone, title: identity.line, detail: identity.detail)
                } else if let error = account.loadError {
                    ErrorNotice(message: error)
                } else {
                    Button { Task { await account.load() } } label: {
                        HStack {
                            Label("Show GitHub account", systemImage: "person.badge.key")
                            if account.reading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(account.reading)
                }
            } header: {
                Text("GitHub account")
            }
            .listRowBackground(Theme.row)
        }
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

    init(_ subject: GithubReadSubject, error: String?, account: ProjectGithubAccountModel) {
        self.subject = subject
        self.error = error
        self.account = account
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

/// A refusal on a screen that keeps no account of its own (an issue's Projects): the note with an account it owns. A call
/// site gives it `.id(repo)`, so a note reused for another repository reads that one's identity.
struct StandaloneGithubRefusalNote: View {
    let subject: GithubReadSubject
    let error: String?
    @StateObject private var account: ProjectGithubAccountModel

    init(_ subject: GithubReadSubject, error: String?, repo: String) {
        self.subject = subject
        self.error = error
        _account = StateObject(wrappedValue: ProjectGithubAccountModel(repo: repo))
    }

    var body: some View { GithubRefusalNote(subject, error: error, account: account) }
}
