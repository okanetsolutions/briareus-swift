// A pull request's Description section on a phone (PullScreen): its body, then the GitHub account the server reads and
// writes GitHub with for the project (the Mac's PullGithubAccountItem in its sidebar), for any token that can read it.
// The account is read only when tapped (`GET /github/account`, which asks GitHub nothing), once, and never polled;
// PullScreen owns its model, so what was read stays while the screen does, whichever section shows.
import SwiftUI

struct PullDescriptionSection: View {
    /// The description's Markdown, from the pull request or its separate read; nil until one of them has it.
    let markdown: String?
    /// Whether the separate description read has answered, so a missing body means there is none.
    let bodyRead: Bool
    let author: String?
    @EnvironmentObject private var store: Store

    var body: some View {
        let loading = markdown == nil && !bodyRead && store.supports("pull_description")
        Section {
            if let markdown {
                let text = visibleMarkdown(markdown)
                if text.isEmpty { Text("No description provided.").italic().foregroundStyle(.secondary) }
                else { MarkdownText(text).font(.callout) }
            } else if loading {
                HStack(spacing: 8) { ProgressView(); Text("Loading the description…").foregroundStyle(.secondary) }
            } else {
                Text("No description provided.").italic().foregroundStyle(.secondary)
            }
        } header: {
            if let author { Text("@\(author)") }
        }
        .listRowBackground(Theme.row)
    }
}

/// The project's GitHub account under the description: Show GitHub account until it is read, then its line.
struct PullGithubAccountSection: View {
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
