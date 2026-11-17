// A pull request's Description section on a phone (PullScreen): its body, with who wrote it. PullScreen draws the project's
// GitHub account under it (GithubAccountSection).
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
